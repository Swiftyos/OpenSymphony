defmodule SymphonyElixir.IapTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.{Auth, Iap, Users}

  @endpoint SymphonyElixirWeb.Endpoint
  @other_audience "/projects/1234/global/backendServices/9999"

  defmodule StubOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      totals = %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      {:reply, %{running: [], retrying: [], agent_totals: totals, rate_limits: nil}, state}
    end

    def handle_call(:request_refresh, _from, state), do: {:reply, %{queued: true}, state}
  end

  setup do
    Auth.clear_cache()
    Users.reset()
    on_exit(fn -> Users.reset() end)
    :ok
  end

  describe "verify/2" do
    test "accepts a token Google's key signed for one of the audiences" do
      token = iap_token("Mia@Acme.test")
      assert {:ok, %{email: "mia@acme.test", subject: "accounts.google.com:Mia@Acme.test"}} = Iap.verify(token, [iap_audience()])
      # Several audiences, so moving the load balancer to a new backend doesn't lock people out.
      assert {:ok, _} = Iap.verify(token, [@other_audience, iap_audience()])
    end

    test "refuses missing, malformed and unsigned tokens" do
      assert Iap.verify(nil, [iap_audience()]) == {:error, :missing}
      assert Iap.verify("not-a-jwt", [iap_audience()]) == {:error, :malformed}
      assert Iap.verify("a.b.c", [iap_audience()]) == {:error, :malformed}
      assert Iap.verify(iap_token("mia@acme.test"), []) == {:error, :no_audience}

      [header, claims, _signature] = String.split(iap_token("mia@acme.test"), ".")
      assert Iap.verify(header <> "." <> claims <> ".", [iap_audience()]) == {:error, :bad_signature}

      # Claims changed after signing.
      forged = Base.url_encode64(Jason.encode!(%{"iss" => "https://cloud.google.com/iap", "aud" => iap_audience(), "email" => "ada@acme.test"}), padding: false)
      [_header, _claims, signature] = String.split(iap_token("mia@acme.test"), ".")
      assert Iap.verify(Enum.join([header, forged, signature], "."), [iap_audience()]) == {:error, :bad_signature}

      none = Base.url_encode64(Jason.encode!(%{"alg" => "none", "kid" => "test-key"}), padding: false)
      assert Iap.verify(Enum.join([none, claims, ""], "."), [iap_audience()]) == {:error, :malformed}

      unknown_kid = Base.url_encode64(Jason.encode!(%{"alg" => "ES256", "kid" => "someone-else"}), padding: false)
      assert Iap.verify(Enum.join([unknown_kid, claims, signature], "."), [iap_audience()]) == {:error, :unknown_key}
    end

    test "refuses another backend's audience, another issuer, expired, future and email-less tokens" do
      now = System.system_time(:second)

      assert Iap.verify(iap_token("mia@acme.test", %{"aud" => @other_audience}), [iap_audience()]) == {:error, :bad_audience}
      assert Iap.verify(iap_token("mia@acme.test", %{"iss" => "https://evil.example"}), [iap_audience()]) == {:error, :bad_issuer}
      assert Iap.verify(iap_token("mia@acme.test", %{"exp" => now - 120}), [iap_audience()]) == {:error, :expired}
      assert Iap.verify(iap_token("mia@acme.test", %{"exp" => nil}), [iap_audience()]) == {:error, :expired}
      assert Iap.verify(iap_token("mia@acme.test", %{"iat" => now + 600}), [iap_audience()]) == {:error, :not_yet_valid}
      assert Iap.verify(iap_token("mia@acme.test", %{"email" => nil}), [iap_audience()]) == {:error, :no_email}
      # A little clock skew is fine.
      assert {:ok, _} = Iap.verify(iap_token("mia@acme.test", %{"exp" => now - 5}), [iap_audience()])
    end
  end

  describe "the dashboard" do
    setup do
      name = Module.concat(__MODULE__, :Orchestrator)
      {:ok, _pid} = StubOrchestrator.start_link(name: name)
      endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
      config = Keyword.merge(endpoint_config, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: name, snapshot_timeout_ms: 200)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
      start_supervised!({SymphonyElixirWeb.Endpoint, []})

      saved_dev_user = System.get_env("SYMPHONY_DEV_USER")

      on_exit(fn ->
        Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
        restore_env("SYMPHONY_DEV_USER", saved_dev_user)
      end)

      :ok
    end

    test "IAP's signed header is required; the plain email header isn't trusted" do
      write_workflow_file!(Workflow.workflow_file_path(), server_host: "0.0.0.0", tracker_kind: "memory")

      assert html_response(get(build_conn(), "/"), 401) =~ "Sign in through Symphony"

      spoofed = build_conn() |> Plug.Conn.put_req_header("x-goog-authenticated-user-email", "accounts.google.com:mia@acme.test")
      assert html_response(get(spoofed, "/"), 401)

      wrong_backend = build_conn() |> Plug.Conn.put_req_header("x-goog-iap-jwt-assertion", iap_token("mia@acme.test", %{"aud" => @other_audience}))
      assert html_response(get(wrong_backend, "/"), 401)
      assert Users.list() == []

      assert html_response(get(iap_conn("mia@acme.test"), "/"), 200)
      assert [%{email: "mia@acme.test"}] = Users.list()
    end

    test "the readiness probe needs no IAP header, while the dashboard does" do
      write_workflow_file!(Workflow.workflow_file_path(), server_host: "0.0.0.0", tracker_kind: "memory")

      assert response(get(build_conn(), "/readyz"), 200) == "ok"
      assert html_response(get(build_conn(), "/"), 401)
    end

    test "every configured audience is accepted" do
      audiences = [@other_audience, iap_audience()]
      config = [server_host: "0.0.0.0", tracker_kind: "memory", server_iap_audiences: audiences]
      write_workflow_file!(Workflow.workflow_file_path(), config)
      assert html_response(get(iap_conn("mia@acme.test"), "/"), 200)

      new_backend = build_conn() |> Plug.Conn.put_req_header("x-goog-iap-jwt-assertion", iap_token("mia@acme.test", %{"aud" => @other_audience}))
      assert html_response(get(new_backend, "/"), 200)
    end

    test "without an audience nothing gets in, except SYMPHONY_DEV_USER on a laptop" do
      write_workflow_file!(Workflow.workflow_file_path(), server_host: "0.0.0.0", tracker_kind: "memory", server_iap_audiences: [])
      System.delete_env("SYMPHONY_DEV_USER")
      assert html_response(get(iap_conn("mia@acme.test"), "/"), 503) =~ "server.iap_audiences"

      System.put_env("SYMPHONY_DEV_USER", "dev@acme.test")
      assert html_response(get(build_conn(), "/"), 200)
      assert [%{email: "dev@acme.test"}] = Users.list()

      # Once an audience is set, the dev user opens nothing.
      write_workflow_file!(Workflow.workflow_file_path(), server_host: "0.0.0.0", tracker_kind: "memory")
      assert html_response(get(build_conn(), "/"), 401)
    end
  end
end
