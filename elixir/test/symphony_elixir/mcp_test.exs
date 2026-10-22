defmodule SymphonyElixir.McpTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.{AgentInbox, Auth, McpTokens, Users}
  alias SymphonyElixir.Factory.Store
  alias SymphonyElixirWeb.RateLimit

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinear do
    def graphql(query, variables, _opts \\ []) do
      if query =~ "SymphonyMemberByEmail",
        do: member(String.downcase(variables[:email])),
        else: {:ok, %{"data" => %{}}}
    end

    defp member("mia@acme.test"), do: users("Mia", false, false, ["PAY"])
    defp member("ada@acme.test"), do: users("Ada", true, false, [])
    defp member("lee@acme.test"), do: users("Lee", false, false, ["PAY"])
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

    %{admin: iap_account!("ada@acme.test"), mia: iap_account!("mia@acme.test")}
  end

  describe "transport and auth" do
    test "is off unless server.mcp.enabled", %{mia: mia} do
      write_config!(mcp: nil)
      {secret, _token} = token!(mia)
      assert json_response(rpc(secret, "ping"), 404)
    end

    test "every request needs a valid, unexpired token", %{mia: mia} do
      conn = rpc(nil, "ping")
      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
      assert [~s(Bearer realm="symphony-mcp", error="invalid_request")] = Plug.Conn.get_resp_header(conn, "www-authenticate")

      assert json_response(rpc("symp_not-a-real-token", "ping"), 401)
      # The dashboard's server.api_token is not an MCP token.
      assert json_response(rpc("api-secret-token-0123456789abcdef", "ping"), 401)
      # Neither IAP sign-in nor a browser session is enough: /mcp sits outside IAP.
      signed_in = iap_conn(mia) |> put_req_header("content-type", "application/json") |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))
      assert json_response(signed_in, 401)

      {secret, _token} = token!(mia)
      assert %{"result" => %{}} = json_response(rpc(secret, "ping"), 200)

      {:ok, _new_secret, _token} = McpTokens.rotate(mia.id)
      assert %{"error" => %{"message" => message}} = json_response(rpc(secret, "ping"), 401)
      assert message =~ "/account/mcp"
    end

    test "disabled accounts' tokens stop working at once", %{mia: mia} do
      {secret, _token} = token!(mia)
      assert json_response(rpc(secret, "ping"), 200)
      {:ok, _} = Users.disable(mia.id, "test")
      assert %{"error" => %{"message" => message}} = json_response(rpc(secret, "ping"), 401)
      assert message =~ "account"
    end

    test "browser origins must be allowed", %{mia: mia} do
      {secret, _token} = token!(mia)
      evil = rpc(secret, "ping", %{}, [{"origin", "https://evil.example"}])
      assert %{"error" => %{"code" => "forbidden_origin"}} = json_response(evil, 403)
      assert json_response(rpc(secret, "ping", %{}, [{"origin", "https://agents.acme.test"}]), 200)
    end

    test "local-operator tokens only work in local mode" do
      {:ok, secret, _token} = McpTokens.current("local")
      assert json_response(rpc(secret, "ping"), 401)

      write_config!(mcp: "    enabled: true", server_host: "127.0.0.1")
      assert json_response(rpc(secret, "ping"), 200)
    end

    test "initialize, notifications, and protocol errors", %{mia: mia} do
      {secret, _token} = token!(mia)

      assert %{"result" => %{"protocolVersion" => "2025-06-18", "serverInfo" => %{"name" => "agent-factory"}, "capabilities" => %{"tools" => _}}} =
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
      {secret, _token} = token!(mia)

      assert build_conn() |> Map.put(:host, "mcp.acme.test") |> get("/") |> response(404)
      assert build_conn() |> Map.put(:host, "mcp.acme.test") |> get("/api/v1/state") |> response(404)
      assert iap_conn(mia) |> Map.put(:host, "mcp.acme.test") |> get("/account/mcp") |> response(404)
      assert json_response(rpc(secret, "ping", %{}, [], "mcp.acme.test"), 200)
      # The dashboard's own host is unaffected.
      assert iap_conn(mia) |> get("/") |> html_response(200)
    end
  end

  describe "tools" do
    test "a token lists every tool; its account's permissions decide what runs", %{mia: mia} do
      {secret, _token} = token!(mia)
      %{"result" => %{"tools" => tools}} = json_response(rpc(secret, "tools/list"), 200)
      names = Enum.map(tools, & &1["name"])

      assert "symphony_status" in names
      assert "save_flow" in names

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               json_response(call(secret, "set_stage_control", %{"scope" => "WEB", "stage" => "todo", "field" => "paused", "value" => true}), 200)

      assert text =~ "Only this team's members"
    end

    test "status and flows are trimmed to what the account may see", %{mia: mia} do
      {secret, _token} = token!(mia)

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

    test "tokens edit their own teams' flows, with conflict checks", %{mia: mia} do
      {secret, _token} = token!(mia)

      %{"result" => %{"structuredContent" => %{"version" => version, "definition" => definition}}} =
        json_response(call(secret, "get_flow", %{"scope" => "PAY"}), 200)

      %{"result" => %{"isError" => false, "structuredContent" => %{"version" => saved_version}}} =
        json_response(call(secret, "save_flow", %{"scope" => "PAY", "base_version" => version, "definition" => definition}), 200)

      assert saved_version == version + 1
      assert Store.get("PAY")["updated_by"] == "mia via MCP"

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
      {secret, _token} = token!(mia)

      assert %{"result" => %{"isError" => false}} = json_response(call(secret, "send_agent_message", %{"identifier" => "PAY-1", "text" => "Use v2"}), 200)
      assert [%{author: "mia via MCP", text: "Use v2"}] = AgentInbox.messages("PAY-1")

      assert %{"result" => %{"isError" => true}} = json_response(call(secret, "send_agent_message", %{"identifier" => "WEB-1", "text" => "hi"}), 200)
      assert AgentInbox.messages("WEB-1") == []
    end

    test "server.controls: false makes changes fail even for admins", %{admin: admin} do
      write_config!(mcp: "    enabled: true\n  controls: false")
      {secret, _token} = token!(admin)

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} = json_response(call(secret, "reset_flow", %{"scope" => "PAY"}), 200)
      assert text =~ "read-only"
    end
  end

  describe "tokens" do
    test "one per account, kept so it can be shown again, and rotation stops the old one", %{mia: mia, admin: admin} do
      {:ok, secret, token} = McpTokens.current(mia.id)
      assert String.starts_with?(secret, "symp_")
      assert {:ok, ^secret, %{id: id}} = McpTokens.current(mia.id)
      assert id == token.id
      assert {:ok, other, _token} = McpTokens.current(admin.id)
      assert other != secret

      # Stored as a hash plus an encrypted copy, never in the clear.
      refute String.contains?(inspect(:ets.tab2list(:symphony_mcp_tokens)), secret)

      {:ok, rotated, _token} = McpTokens.rotate(mia.id)
      assert rotated != secret
      assert McpTokens.verify(secret) == {:error, :invalid_token}
      assert {:ok, %{account_id: account_id}} = McpTokens.verify(rotated)
      assert account_id == mia.id
      assert {:ok, ^rotated, _token} = McpTokens.current(mia.id)
      assert {:ok, ^other, _token} = McpTokens.current(admin.id)
      assert McpTokens.current("") == {:error, :invalid_account}
    end

    test "the setup page shows the current token in every harness's command, and rotates it", %{mia: mia} do
      page = iap_conn(mia) |> get("/account/mcp") |> html_response(200)
      {:ok, secret, _token} = McpTokens.current(mia.id)

      assert page =~ "Connect your agents"
      assert page =~ ~s(claude mcp add --transport http --scope user agent-factory http://www.example.com:80/mcp --header &quot;Authorization: Bearer #{secret}&quot;)
      assert page =~ "mcp-remote"
      assert page =~ "[mcp_servers.agent-factory]"
      assert page =~ "codex mcp remove symphony"
      assert page =~ "Codex desktop app"
      assert page =~ "grok mcp add --transport http agent-factory"
      assert page =~ "Rotate token"

      rotated_page = iap_conn(mia) |> post("/account/mcp-token/rotate") |> html_response(200)
      {:ok, rotated, _token} = McpTokens.current(mia.id)
      assert rotated != secret
      assert rotated_page =~ "The old one stopped working"
      assert rotated_page =~ rotated
      refute rotated_page =~ secret
      assert json_response(rpc(secret, "ping"), 401)
      assert json_response(rpc(rotated, "ping"), 200)

      # Rotating needs IAP sign-in.
      assert build_conn() |> post("/account/mcp-token/rotate") |> html_response(401)
      assert {:ok, ^rotated, _token} = McpTokens.current(mia.id)

      # The page is off with MCP.
      write_config!(mcp: nil)
      assert redirected_to(get(iap_conn(mia), "/account/mcp")) == "/"
    end

    test "the setup opens once, on someone's first visit, and dismissing it is remembered", %{mia: mia, admin: admin} do
      {:ok, view, html} = live(iap_conn(mia), "/")
      {:ok, secret, _token} = McpTokens.current(mia.id)
      assert html =~ "Connect your agents to"
      assert html =~ secret
      assert html =~ "Claude Desktop"
      assert html =~ "Grok"

      refute view |> element(~s(button[phx-click="dismiss_mcp_setup"])) |> render_click() =~ "Connect your agents to"
      assert is_binary(Users.get(mia.id).mcp_welcomed_at)
      {:ok, _view, html} = live(iap_conn(mia), "/")
      refute html =~ "Connect your agents to"

      # Opening the setup page counts as having seen it.
      iap_conn(admin) |> get("/account/mcp") |> html_response(200)
      {:ok, _view, html} = live(iap_conn(admin), "/")
      refute html =~ "Connect your agents to"

      # Not while MCP is off.
      lee = iap_account!("lee@acme.test")
      write_config!(mcp: nil)
      {:ok, _view, html} = live(iap_conn(lee), "/")
      refute html =~ "Connect your agents to"
      assert Users.get(lee.id).mcp_welcomed_at == nil
    end

    test "tokens from before rotation are dropped at load, even unexpired ones", %{mia: mia} do
      dir = Path.join(System.tmp_dir!(), "mcp-legacy-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      path = Path.join(dir, "mcp_tokens.json")
      future = DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.to_iso8601()
      hash = &(:crypto.hash(:sha256, &1) |> Base.encode16(case: :lower))

      tokens = [
        # A read-only token limited to WEB, from the old design: it must not gain Mia's access.
        %{hash: hash.("symp_legacy-read"), id: "tok_old", name: "old", account_id: mia.id, scopes: ["read"], resources: ["WEB"], expires_at: future},
        %{hash: hash.("symp_legacy-forever"), id: "tok_nodate", account_id: mia.id, scopes: ["read"], resources: ["PAY"]}
      ]

      File.write!(path, Jason.encode!(%{version: 1, tokens: tokens}))
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, McpTokens)
      on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, McpTokens) end)
      start_supervised!({McpTokens, path: path})

      assert json_response(rpc("symp_legacy-read", "ping"), 401)
      assert json_response(rpc("symp_legacy-forever", "ping"), 401)
      refute File.read!(path) =~ "tok_old"

      # Mia's first visit gives her a working token.
      page = iap_conn(mia) |> get("/account/mcp") |> html_response(200)
      assert [secret] = Regex.run(~r/symp_[A-Za-z0-9_-]{20,}/, page)
      assert json_response(rpc(secret, "ping"), 200)
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

  defp token!(account) do
    {:ok, secret, token} = McpTokens.current(account.id)
    {secret, token}
  end

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
end
