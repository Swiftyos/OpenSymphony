defmodule SymphonyElixir.SecurityTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{Auth, PrivateFile, UsageLedger, Users}
  alias SymphonyElixirWeb.{RateLimit, RequestGuards, Visibility}

  @endpoint SymphonyElixirWeb.Endpoint
  @password "correct horse battery"

  defmodule FakeLinear do
    def fetch_issue_states_by_ids(ids) do
      {:ok,
       for id <- ids, String.starts_with?(id, "id-PAY-") do
         identifier = String.replace_prefix(id, "id-", "")
         %SymphonyElixir.Linear.Issue{id: id, identifier: identifier, title: "x", state: "In Review", labels: [], project_slug: "project"}
       end}
    end

    def graphql(query, variables, _opts \\ []) do
      cond do
        query =~ "SymphonyMemberByEmail" -> member(String.downcase(variables[:email]))
        query =~ "SymphonyStageLookup" -> {:ok, %{"data" => stage_lookup()}}
        query =~ "SymphonySetStage" -> {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
        query =~ "SymphonyCreateComment" -> send_test({:comment, variables}) && {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
        true -> {:ok, %{"data" => %{}}}
      end
    end

    defp stage_lookup do
      %{
        "issue" => %{"team" => %{"id" => "t-PAY", "states" => %{"nodes" => [%{"id" => "s"}]}}, "labels" => %{"nodes" => []}},
        "issueLabels" => %{"nodes" => [%{"id" => "l", "team" => %{"id" => "t-PAY"}}]}
      }
    end

    defp member("mia@acme.test"), do: users("Mia [click](https://evil.test)", false, ["PAY"])
    defp member("ada@acme.test"), do: users("Ada Admin", true, [])
    defp member(_email), do: {:ok, %{"data" => %{"users" => %{"nodes" => []}}}}

    defp users(name, admin, teams) do
      nodes = Enum.map(teams, &%{"id" => "t-" <> &1, "key" => &1, "name" => &1})
      user = %{"id" => "u-" <> name, "displayName" => name, "admin" => admin, "guest" => false, "active" => true, "teams" => %{"nodes" => nodes}}
      {:ok, %{"data" => %{"users" => %{"nodes" => [user]}}}}
    end

    defp send_test(message) do
      if pid = Application.get_env(:symphony_elixir, :fake_linear_recipient), do: send(pid, message)
      true
    end
  end

  defmodule StubOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      running =
        for identifier <- ["PAY-1", "WEB-1"] do
          %{
            issue_id: "id-" <> identifier,
            identifier: identifier,
            issue_title: "Task " <> identifier,
            issue_url: nil,
            state: "In Progress",
            labels: [],
            backend: "claude",
            effort: nil,
            workspace_path: "/srv/symphony/" <> identifier,
            worker_host: "build-1",
            session_id: "sess-" <> identifier,
            turn_count: 1,
            agent_input_tokens: 1,
            agent_output_tokens: 1,
            agent_total_tokens: 2,
            agent_server_pid: nil,
            last_agent_message: nil,
            last_agent_timestamp: nil,
            last_agent_event: :notification,
            project_id: nil,
            project_slug: "project",
            project_name: "Project",
            account: nil,
            account_id: nil,
            account_email: nil,
            account_state: nil,
            account_credential_kind: nil,
            started_at: DateTime.utc_now()
          }
        end

      totals = %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      {:reply, %{running: running, retrying: [], agent_totals: totals, rate_limits: nil}, state}
    end

    def handle_call(:request_refresh, _from, state), do: {:reply, %{queued: true}, state}
  end

  setup do
    Auth.clear_cache()
    Users.reset()
    RateLimit.reset()
    UsageLedger.reset()
    saved = Map.new([:linear_client_module, :fake_linear_recipient, :enforce_local_host], &{&1, Application.get_env(:symphony_elixir, &1)})
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinear)
    Application.put_env(:symphony_elixir, :fake_linear_recipient, self())

    on_exit(fn ->
      Auth.clear_cache()
      Users.reset()
      UsageLedger.reset()

      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)

      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  defp accounts_mode! do
    write_workflow_file!(Workflow.workflow_file_path(), server_host: "0.0.0.0", tracker_kind: "linear", tracker_api_token: "server-key")
  end

  defp start_endpoint! do
    name = Module.concat(__MODULE__, :Orchestrator)
    {:ok, _pid} = StubOrchestrator.start_link(name: name)

    config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: name, snapshot_timeout_ms: 200)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp register!(username, email) do
    params = %{"username" => username, "email" => email, "password" => @password, "setup_code" => Users.setup_code()}
    {:ok, account} = Users.register(params, &Auth.check_linear_member/1)
    {:ok, account} = if account.status == "pending", do: Users.approve(account.id, "test"), else: {:ok, account}
    account
  end

  defp session_for(account) do
    build_conn() |> Plug.Test.init_test_session(%{"user_id" => account.id, "session_version" => Users.get(account.id).session_version})
  end

  describe "with accounts" do
    setup do
      accounts_mode!()
      start_endpoint!()
      admin = register!("ada", "ada@acme.test")
      mia = register!("mia", "mia@acme.test")
      %{admin: admin, mia: mia}
    end

    test "members only see their own teams' work, without host details", %{admin: admin, mia: mia} do
      payload = session_for(mia) |> get("/api/v1/state") |> json_response(200)
      assert Enum.map(payload["running"], & &1["issue_identifier"]) == ["PAY-1"]
      refute Map.has_key?(hd(payload["running"]), "workspace_path")
      refute Map.has_key?(hd(payload["running"]), "worker_host")
      assert payload["counts"]["running"] == 1

      assert json_response(get(session_for(mia), "/api/v1/WEB-1"), 404)

      admin_payload = session_for(admin) |> get("/api/v1/state") |> json_response(200)
      assert length(admin_payload["running"]) == 2
      assert hd(admin_payload["running"])["workspace_path"]

      {:ok, _view, html} = live(session_for(mia), "/")
      assert html =~ "PAY-1"
      refute html =~ "WEB-1"
      refute html =~ "/srv/symphony"
    end

    test "stored non-https links are never rendered" do
      UsageLedger.observe_issue(%Issue{id: "id-PAY-9", identifier: "PAY-9", title: "Phish", state: "In Review", url: "javascript:alert(1)"})
      {:ok, _view, html} = live(session_for(Users.list() |> Enum.find(&(&1.username == "ada"))), "/")
      assert html =~ "PAY-9"
      refute html =~ "javascript:"
    end

    test "disabled accounts lose access on pages that were already open", %{mia: mia} do
      stale_session = session_for(mia)
      {:ok, mia_view, _html} = live(stale_session, "/")

      {:ok, _} = Users.disable(mia.id, "ada")

      # The already-open page re-checks the account before acting.
      render_hook(mia_view, "factory_move", %{"id" => "id-PAY-1", "action" => "approve"})
      assert_reply(mia_view, %{ok: false, error: "Your session ended" <> _})

      # And the old session can't mount a new page.
      assert {:error, {:redirect, %{to: "/login"}}} = live(stale_session, "/")
    end

    test "attribution comments escape names so they can't add links", %{mia: mia} do
      {:ok, view, _html} = live(session_for(mia), "/")
      render_hook(view, "factory_move", %{"id" => "id-PAY-2", "action" => "approve"})
      assert_reply(view, %{ok: true})
      assert_receive {:comment, %{issueId: "id-PAY-2", body: body}}
      refute body =~ "[click](https://evil.test)"
      assert body =~ ~S"\[click\]\(https://evil\.test\)"
    end
  end

  test "without sign-in the server only answers on localhost" do
    write_workflow_file!(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :enforce_local_host, true)

    blocked = RequestGuards.local_host_only(%{build_conn() | host: "evil.example"}, [])
    assert blocked.halted
    assert blocked.status == 421

    for host <- ["localhost", "127.0.0.1", "[::1]"] do
      refute RequestGuards.local_host_only(%{build_conn() | host: host}, []).halted
    end
  end

  test "proxy headers are only trusted when configured" do
    conn =
      build_conn()
      |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.9, 10.0.0.2")
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")

    write_workflow_file!(Workflow.workflow_file_path())
    untrusted = RequestGuards.proxy_headers(conn, [])
    assert untrusted.remote_ip == {127, 0, 0, 1}
    refute RequestGuards.https?(untrusted)

    write_workflow_file!(Workflow.workflow_file_path(), server_trust_proxy: true)
    trusted = RequestGuards.proxy_headers(conn, [])
    # The last hop is the address our proxy received the request from.
    assert trusted.remote_ip == {10, 0, 0, 2}
    assert RequestGuards.https?(trusted)
  end

  test "private state files are owner-only from the moment they exist" do
    dir = Path.join(System.tmp_dir!(), "symphony-private-#{System.unique_integer([:positive])}")

    try do
      path = Path.join(dir, "users.json")
      assert :ok = PrivateFile.write(path, "{}")
      assert {:ok, %{mode: dir_mode}} = File.stat(dir)
      assert {:ok, %{mode: file_mode}} = File.stat(path)
      assert Bitwise.band(dir_mode, 0o777) == 0o700
      assert Bitwise.band(file_mode, 0o777) == 0o600
      assert Path.wildcard(path <> ".tmp-*") == []

      secret = Path.join(dir, "secret_key_base")
      assert {:ok, "first"} = PrivateFile.create_once(secret, "first")
      assert {:ok, "first"} = PrivateFile.create_once(secret, "second")
      assert {:ok, %{mode: secret_mode}} = File.stat(secret)
      assert Bitwise.band(secret_mode, 0o777) == 0o600
    after
      File.rm_rf!(dir)
    end
  end

  test "visibility leaves admin and API-token payloads untouched" do
    payload = %{running: [%{issue_identifier: "WEB-1", workspace_path: "/x"}], retrying: []}
    assert Visibility.filter_payload(payload, nil) == payload
    assert Visibility.filter_payload(payload, Auth.local_user()) == payload
  end
end
