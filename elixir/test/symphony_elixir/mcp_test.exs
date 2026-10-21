defmodule SymphonyElixir.McpTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.{AgentInbox, Auth, McpTokens, Users}
  alias SymphonyElixir.Factory.Store
  alias SymphonyElixirWeb.RateLimit

  @endpoint SymphonyElixirWeb.Endpoint
  @password "correct horse battery"

  defmodule FakeLinear do
    def graphql(query, variables, _opts \\ []) do
      if query =~ "SymphonyMemberByEmail",
        do: member(String.downcase(variables[:email])),
        else: {:ok, %{"data" => %{}}}
    end

    defp member("mia@acme.test"), do: users("Mia", false, false, ["PAY"])
    defp member("ada@acme.test"), do: users("Ada", true, false, [])
    defp member(_email), do: {:ok, %{"data" => %{"users" => %{"nodes" => []}}}}

    defp users(name, admin, guest, teams) do
      nodes = Enum.map(teams, &%{"id" => "t-" <> &1, "key" => &1, "name" => &1})
      user = %{"id" => "u-" <> name, "displayName" => name, "admin" => admin, "guest" => guest, "active" => true, "teams" => %{"nodes" => nodes}}
      {:ok, %{"data" => %{"users" => %{"nodes" => [user]}}}}
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

    def handle_call(:request_refresh, _from, state), do: {:reply, %{queued: true, requested_at: DateTime.utc_now()}, state}
  end

  setup do
    Auth.clear_cache()
    Users.reset()
    RateLimit.reset()
    McpTokens.reset()
    AgentInbox.reset()
    Store.reset()
    saved_client = Application.get_env(:symphony_elixir, :linear_client_module)
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinear)

    on_exit(fn ->
      Auth.clear_cache()
      Users.reset()
      McpTokens.reset()
      AgentInbox.reset()
      Store.reset()

      if saved_client,
        do: Application.put_env(:symphony_elixir, :linear_client_module, saved_client),
        else: Application.delete_env(:symphony_elixir, :linear_client_module)

      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    write_config!(mcp: "    enabled: true\n    allowed_origins: [\"https://agents.acme.test\"]")

    name = Module.concat(__MODULE__, :Orchestrator)
    {:ok, _pid} = StubOrchestrator.start_link(name: name)
    config = Keyword.merge(endpoint_config, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: name, snapshot_timeout_ms: 200)
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    %{admin: register!("ada", "ada@acme.test"), mia: register!("mia", "mia@acme.test")}
  end

  describe "transport and auth" do
    test "is off unless server.mcp.enabled", %{mia: mia} do
      write_config!(mcp: nil)
      {secret, _token} = token!(mia, ["read"])
      assert json_response(rpc(secret, "ping"), 404)
    end

    test "every request needs a valid, unexpired token", %{mia: mia} do
      conn = rpc(nil, "ping")
      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
      assert [~s(Bearer realm="symphony-mcp", error="invalid_request")] = Plug.Conn.get_resp_header(conn, "www-authenticate")

      assert json_response(rpc("symp_not-a-real-token", "ping"), 401)
      # The dashboard's server.api_token is not an MCP token.
      assert json_response(rpc("api-secret-token-0123456789abcdef", "ping"), 401)
      # A browser session alone is not enough either.
      session = session_for(mia) |> put_req_header("content-type", "application/json") |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      assert json_response(session, 401)

      {secret, token} = token!(mia, ["read"])
      assert %{"result" => %{}} = json_response(rpc(secret, "ping"), 200)

      :ok = McpTokens.revoke(mia.id, token.id)
      assert json_response(rpc(secret, "ping"), 401)
    end

    test "disabled accounts' tokens stop working at once", %{mia: mia} do
      {secret, _token} = token!(mia, ["read"])
      assert json_response(rpc(secret, "ping"), 200)
      {:ok, _} = Users.disable(mia.id, "test")
      assert %{"error" => %{"message" => message}} = json_response(rpc(secret, "ping"), 401)
      assert message =~ "account"
    end

    test "browser origins must be allowed", %{mia: mia} do
      {secret, _token} = token!(mia, ["read"])
      evil = rpc(secret, "ping", %{}, [{"origin", "https://evil.example"}])
      assert %{"error" => %{"code" => "forbidden_origin"}} = json_response(evil, 403)
      assert json_response(rpc(secret, "ping", %{}, [{"origin", "https://agents.acme.test"}]), 200)
    end

    test "local-operator tokens only work in local mode" do
      {:ok, secret, _token} = McpTokens.create("local", "ops", ["read"], 7, ["*"])
      assert json_response(rpc(secret, "ping"), 401)

      write_config!(mcp: "    enabled: true", server_host: "127.0.0.1")
      assert json_response(rpc(secret, "ping"), 200)
    end

    test "initialize, notifications, and protocol errors", %{mia: mia} do
      {secret, _token} = token!(mia, ["read"])

      assert %{"result" => %{"protocolVersion" => "2025-06-18", "serverInfo" => %{"name" => "symphony"}, "capabilities" => %{"tools" => _}}} =
               json_response(rpc(secret, "initialize", %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}), 200)

      assert %{"result" => %{"protocolVersion" => "2025-11-25"}} = json_response(rpc(secret, "initialize", %{"protocolVersion" => "1999-01-01"}), 200)

      notification = post_json(secret, %{jsonrpc: "2.0", method: "notifications/initialized"})
      assert notification.status == 202

      assert %{"error" => %{"code" => -32_601}} = json_response(rpc(secret, "prompts/list"), 200)
      assert %{"error" => %{"code" => -32_600}} = json_response(post_json(secret, [%{jsonrpc: "2.0", id: 1, method: "ping"}]), 400)
      assert %{"error" => %{"code" => -32_600}} = json_response(rpc(secret, "ping", %{}, [{"mcp-protocol-version", "1999-01-01"}]), 400)
      assert %{"error" => %{"code" => -32_602}} = json_response(rpc(secret, "tools/call", %{"name" => "rm_rf"}), 200)

      assert json_response(build_conn() |> get("/mcp"), 405)
    end

    test "with server.mcp.host set, that host only reaches /mcp", %{mia: mia} do
      write_config!(mcp: "    enabled: true\n    host: mcp.acme.test")
      {secret, _token} = token!(mia, ["read"])

      assert build_conn() |> Map.put(:host, "mcp.acme.test") |> get("/") |> response(404)
      assert build_conn() |> Map.put(:host, "mcp.acme.test") |> get("/api/v1/state") |> response(404)
      assert build_conn() |> Map.put(:host, "mcp.acme.test") |> get("/login") |> response(404)
      assert json_response(rpc(secret, "ping", %{}, [], "mcp.acme.test"), 200)
      # The dashboard's own host is unaffected.
      assert build_conn() |> get("/login") |> html_response(200)
    end
  end

  describe "tools" do
    test "read tokens only list and run read tools", %{mia: mia} do
      {secret, _token} = token!(mia, ["read"])
      %{"result" => %{"tools" => tools}} = json_response(rpc(secret, "tools/list"), 200)
      names = Enum.map(tools, & &1["name"])

      assert "symphony_status" in names
      refute "save_flow" in names
      assert Enum.all?(tools, &(&1["annotations"]["readOnlyHint"] == true))

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               json_response(call(secret, "set_stage_control", %{"scope" => "PAY", "stage" => "todo", "field" => "paused", "value" => true}), 200)

      assert text =~ "read-only"
    end

    test "status and flows are trimmed to what the account may see", %{mia: mia} do
      {secret, _token} = token!(mia, ["read"])

      assert %{"result" => %{"isError" => false, "structuredContent" => %{"counts" => %{"running" => 0}}}} =
               json_response(call(secret, "symphony_status"), 200)

      %{"result" => %{"structuredContent" => %{"flows" => flows}}} = json_response(call(secret, "list_flows"), 200)
      assert Enum.map(flows, & &1["key"]) == ["PAY"]
      assert [%{"editable" => true}] = flows

      assert %{"result" => %{"structuredContent" => %{"version" => _, "definition" => %{"stages" => [_ | _]}}}} =
               json_response(call(secret, "get_flow", %{"scope" => "PAY"}), 200)

      assert %{"result" => %{"isError" => true}} = json_response(call(secret, "get_flow", %{"scope" => "WEB"}), 200)
      assert %{"result" => %{"isError" => true}} = json_response(call(secret, "get_issue", %{"identifier" => "WEB-1"}), 200)
      assert %{"result" => %{"isError" => false}} = json_response(call(secret, "get_issue", %{"identifier" => "PAY-1"}), 200)
    end

    test "write tokens edit their own teams' flows, with conflict checks", %{mia: mia} do
      {secret, _token} = token!(mia, ["read", "write"])

      %{"result" => %{"structuredContent" => %{"version" => version, "definition" => definition}}} =
        json_response(call(secret, "get_flow", %{"scope" => "PAY"}), 200)

      %{"result" => %{"isError" => false, "structuredContent" => %{"version" => saved_version}}} =
        json_response(call(secret, "save_flow", %{"scope" => "PAY", "base_version" => version, "definition" => definition}), 200)

      assert saved_version == version + 1
      assert Store.get("PAY")["updated_by"] == "mia via MCP (agent)"

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => conflict}]}} =
               json_response(call(secret, "save_flow", %{"scope" => "PAY", "base_version" => version, "definition" => definition}), 200)

      assert conflict =~ "Re-read it"

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => denied}]}} =
               json_response(call(secret, "save_flow", %{"scope" => "WEB", "base_version" => 0, "definition" => definition}), 200)

      assert denied =~ "Only this team's members"

      [stage | _] = Enum.filter(definition["stages"], &(&1["kind"] in ["queue", "agent"]))

      assert %{"result" => %{"isError" => false, "structuredContent" => %{"controls" => %{"paused" => true}}}} =
               json_response(call(secret, "set_stage_control", %{"scope" => "PAY", "stage" => stage["id"], "field" => "paused", "value" => true}), 200)
    end

    test "messages to agents follow the dashboard's rules", %{mia: mia} do
      {secret, _token} = token!(mia, ["read", "write"])

      assert %{"result" => %{"isError" => false}} = json_response(call(secret, "send_agent_message", %{"identifier" => "PAY-1", "text" => "Use v2"}), 200)
      assert [%{author: "mia via MCP (agent)", text: "Use v2"}] = AgentInbox.messages("PAY-1")

      assert %{"result" => %{"isError" => true}} = json_response(call(secret, "send_agent_message", %{"identifier" => "WEB-1", "text" => "hi"}), 200)
      assert AgentInbox.messages("WEB-1") == []
    end

    test "server.controls: false makes changes fail even for admins", %{admin: admin} do
      write_config!(mcp: "    enabled: true\n  controls: false")
      {secret, _token} = token!(admin, ["read", "write"])

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} = json_response(call(secret, "reset_flow", %{"scope" => "PAY"}), 200)
      assert text =~ "read-only"
    end
  end

  describe "tokens" do
    test "are stored hashed, expire, and are capped per account", %{mia: mia} do
      {secret, token} = token!(mia, ["write"])
      assert token.scopes == ["read", "write"]
      assert String.starts_with?(secret, "symp_")
      refute String.contains?(inspect(McpTokens.list(mia.id)), secret)

      assert {:error, :lifetime_too_long} = McpTokens.create(mia.id, "x", ["read"], 91, ["PAY"])
      assert {:error, :invalid_scopes} = McpTokens.create(mia.id, "x", ["admin"], 7, ["PAY"])
      assert {:error, :name_required} = McpTokens.create(mia.id, " ", ["read"], 7, ["PAY"])

      for n <- 2..20, do: {:ok, _, _} = McpTokens.create(mia.id, "t#{n}", ["read"], 7, ["PAY"])
      assert {:error, :too_many_tokens} = McpTokens.create(mia.id, "t21", ["read"], 7, ["PAY"])
    end

    test "are created and revoked from the token page", %{mia: mia} do
      page = session_for(mia) |> get("/account/mcp") |> html_response(200)
      assert page =~ "MCP tokens"

      created =
        session_for(mia)
        |> post("/account/mcp-tokens", %{"name" => "ops bot", "access" => "write", "days" => "30", "resources" => ["PAY"]})
        |> html_response(200)

      assert [secret] = Regex.run(~r/symp_[A-Za-z0-9_-]{43}/, created)
      assert [%{name: "ops bot", scopes: ["read", "write"], resources: ["PAY"], id: id}] = McpTokens.list(mia.id)
      assert json_response(rpc(secret, "ping"), 200)

      session_for(mia) |> post("/account/mcp-tokens/#{id}/revoke") |> html_response(200)
      assert McpTokens.list(mia.id) == []
      assert json_response(rpc(secret, "ping"), 401)
    end
  end

  defp write_config!(opts) do
    {mcp, overrides} = Keyword.pop(opts, :mcp)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [server_host: "0.0.0.0", server_api_token: "api-secret-token-0123456789abcdef", tracker_kind: "linear", tracker_api_token: "server-key"],
        overrides
      )
    )

    path = Workflow.workflow_file_path()
    content = File.read!(path)
    content = if mcp, do: String.replace(content, "\nserver:\n", "\nserver:\n  mcp:\n#{mcp}\n", global: false), else: content
    File.write!(path, content)
    WorkflowStore.force_reload()
  end

  defp token!(account, scopes) do
    {:ok, secret, token} = McpTokens.create(account.id, "agent", scopes, 30, resources_for(account))
    {secret, token}
  end

  # Admins get everything; members their team.
  defp resources_for(%{username: "ada"}), do: ["*"]
  defp resources_for(_account), do: ["PAY"]

  defp call(secret, tool, args \\ %{}), do: rpc(secret, "tools/call", %{"name" => tool, "arguments" => args})

  defp rpc(secret, method, params \\ %{}, headers \\ [], host \\ nil) do
    body = %{jsonrpc: "2.0", id: System.unique_integer([:positive]), method: method, params: params}
    post_json(secret, body, headers, host)
  end

  defp post_json(secret, body, headers \\ [], host \\ nil) do
    conn = build_conn() |> put_req_header("content-type", "application/json")
    conn = if host, do: Map.put(conn, :host, host), else: conn
    conn = if secret, do: put_req_header(conn, "authorization", "Bearer " <> secret), else: conn
    conn = Enum.reduce(headers, conn, fn {key, value}, acc -> put_req_header(acc, key, value) end)
    post(conn, "/mcp", Jason.encode!(body))
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
end
