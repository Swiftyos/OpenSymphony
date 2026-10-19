defmodule SymphonyElixir.AuthTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{Auth, FactoryControls, UsageLedger}

  @endpoint SymphonyElixirWeb.Endpoint

  @member_key "lin_api_member_0000000000000000"
  @admin_key "lin_api_admin_00000000000000000"
  @outsider_key "lin_api_outsider_00000000000000"
  @inactive_key "lin_api_inactive_00000000000000"

  defmodule FakeLinear do
    @org %{"id" => "org-1", "urlKey" => "acme", "name" => "Acme"}

    def graphql(query, _variables, opts \\ []) do
      cond do
        query =~ "SymphonyOrganization" -> {:ok, %{"data" => %{"organization" => @org}}}
        query =~ "SymphonyViewer" -> viewer(Keyword.get(opts, :api_key))
      end
    end

    defp viewer("lin_api_member_" <> _), do: ok(user("u-1", "Mia Member", false, [team("PAY")]))
    defp viewer("lin_api_admin_" <> _), do: ok(user("u-2", "Ada Admin", true, []))
    defp viewer("lin_api_outsider_" <> _), do: ok(Map.put(user("u-3", "Out Sider", false, []), "organization", %{"id" => "org-2"}))
    defp viewer("lin_api_inactive_" <> _), do: ok(Map.put(user("u-4", "Gone", false, []), "active", false))
    defp viewer(_key), do: {:error, {:linear_api_status, 401}}

    defp ok(viewer), do: {:ok, %{"data" => %{"viewer" => viewer}}}
    defp team(key), do: %{"id" => "team-" <> key, "key" => key, "name" => key <> " team"}

    defp user(id, name, admin, teams) do
      %{
        "id" => id,
        "name" => name,
        "displayName" => name,
        "email" => String.downcase(String.replace(name, " ", ".")) <> "@acme.test",
        "admin" => admin,
        "guest" => false,
        "active" => true,
        "organization" => @org,
        "teams" => %{"nodes" => teams}
      }
    end
  end

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
    FactoryControls.reset()
    UsageLedger.reset()
    client = Application.get_env(:symphony_elixir, :linear_client_module)
    memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinear)

    on_exit(fn ->
      Auth.clear_cache()
      FactoryControls.reset()
      UsageLedger.reset()
      restore_app_env(:linear_client_module, client)
      restore_app_env(:memory_tracker_issues, memory_issues)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp linear_mode!(overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge([server_host: "0.0.0.0", tracker_kind: "linear", tracker_api_token: "server-key"], overrides)
    )
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

  defp signed_in(key), do: build_conn() |> Plug.Test.init_test_session(%{"linear_api_key" => key})

  test "mode is local on loopback and Linear sign-in everywhere else" do
    write_workflow_file!(Workflow.workflow_file_path())
    assert Auth.mode() == :local

    linear_mode!()
    assert Auth.mode() == :linear
  end

  test "sign-in accepts members of the same Linear workspace only" do
    linear_mode!()

    assert {:ok, %Auth.User{name: "Mia Member", admin: false, teams: [%{key: "PAY"}]}} = Auth.sign_in(@member_key)
    assert {:error, :wrong_organization} = Auth.sign_in(@outsider_key)
    assert {:error, :inactive_user} = Auth.sign_in(@inactive_key)
    assert {:error, :invalid_key} = Auth.sign_in("lin_api_unknown_000000000000000")
    assert {:error, :invalid_key} = Auth.sign_in("short")
  end

  test "permissions follow Linear team membership and admin rights" do
    linear_mode!()
    {:ok, member} = Auth.sign_in(@member_key)
    {:ok, admin} = Auth.sign_in(@admin_key)

    assert Auth.can_move?(member, "PAY-12")
    refute Auth.can_move?(member, "WEB-3")
    refute Auth.can_control?(member)
    assert Auth.movable_teams(member) == ["PAY"]

    assert Auth.can_move?(admin, "WEB-3")
    assert Auth.can_control?(admin)
    assert Auth.movable_teams(admin) == :all

    assert Auth.can_control?(Auth.local_user())
  end

  describe "web" do
    setup do
      linear_mode!()
      start_endpoint!()
      :ok
    end

    test "signed-out visitors are sent to sign in and the API asks for a key" do
      assert redirected_to(get(build_conn(), "/")) == "/login"
      assert html_response(get(build_conn(), "/login"), 200) =~ "Linear API key"

      conn = get(build_conn(), "/api/v1/state")
      assert json_response(conn, 401)["error"]["code"] == "unauthorized"

      conn = build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer " <> @member_key) |> get("/api/v1/state")
      assert conn.status == 200
    end

    test "signing in with a Linear key opens the dashboard as that user" do
      conn = post(build_conn(), "/login", %{"api_key" => @outsider_key})
      assert html_response(conn, 401) =~ "different Linear workspace"

      conn = post(build_conn(), "/login", %{"api_key" => @member_key})
      assert redirected_to(conn) == "/"

      conn = conn |> recycle() |> get("/")
      assert html_response(conn, 200) =~ "Mia Member"

      conn = conn |> recycle() |> get("/logout")
      assert redirected_to(conn) == "/login"
      assert redirected_to(conn |> recycle() |> get("/")) == "/login"
    end

    test "members move their own team's issues; only admins change stage controls" do
      linear_mode!(tracker_kind: "memory")
      issue = %Issue{id: "id-PAY-1", identifier: "PAY-1", title: "Refunds", state: "In Review", labels: []}
      other = %Issue{id: "id-WEB-1", identifier: "WEB-1", title: "Cart", state: "In Review", labels: []}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, other])

      {:ok, view, _html} = live(signed_in(@member_key), "/")

      render_hook(view, "factory_move", %{"id" => "id-WEB-1", "issue" => "WEB-1", "action" => "approve"})
      assert_reply(view, %{ok: false, error: "You can only move issues from teams you belong to" <> _})

      render_hook(view, "factory_move", %{"id" => "id-PAY-1", "issue" => "PAY-1", "action" => "approve"})
      assert_reply(view, %{ok: true})

      render_hook(view, "factory_control", %{"stage" => "merge", "field" => "paused", "value" => true})
      assert_reply(view, %{ok: false, error: "Only Linear admins" <> _})

      {:ok, admin_view, _html} = live(signed_in(@admin_key), "/")
      render_hook(admin_view, "factory_control", %{"stage" => "merge", "field" => "paused", "value" => true})
      assert_reply(admin_view, %{ok: true})
      assert FactoryControls.paused?("merge")
    end
  end
end
