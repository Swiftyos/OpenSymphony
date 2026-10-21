defmodule SymphonyElixir.McpToolsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.{AgentInbox, Auth, IssueMoves, McpTokens, Transcript, UsageLedger, Users}
  alias SymphonyElixir.Factory.Store
  alias SymphonyElixirWeb.Mcp.Tools
  alias SymphonyElixirWeb.{McpAuth, RateLimit}

  @endpoint SymphonyElixirWeb.Endpoint
  @password "correct horse battery"
  @orchestrator Module.concat(__MODULE__, :Orchestrator)

  defmodule FakeLinear do
    def graphql(query, variables, _opts \\ []) do
      send(Application.get_env(:symphony_elixir, :fake_linear_recipient), {:graphql, query, variables})

      cond do
        query =~ "SymphonyMemberByEmail" -> member(String.downcase(variables[:email]))
        query =~ "SymphonyStageLookup" -> {:ok, %{"data" => stage_lookup(variables)}}
        query =~ "SymphonySetStage" -> {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
        query =~ "SymphonyCreateComment" -> {:ok, %{"data" => %{"commentCreate" => %{"success" => variables.issueId != "id-PAY-2"}}}}
        query =~ "SymphonyProjectTeams" -> {:ok, %{"data" => %{"projects" => %{"nodes" => project_nodes(variables.slugs)}}}}
        true -> {:ok, %{"data" => %{"teams" => %{"nodes" => []}, "issueLabels" => %{"nodes" => []}}}}
      end
    end

    def fetch_issue_states_by_ids(["id-DOWN-1"]), do: {:error, :linear_down}

    def fetch_issue_states_by_ids(ids) do
      {:ok,
       for id <- ids, String.starts_with?(id, "id-") do
         identifier = String.replace_prefix(id, "id-", "")

         {state, labels} =
           case identifier do
             "PAY-2" -> {"In Progress", ["factory/merge"]}
             "PAY-3" -> {"In Progress", ["factory/merge", "needs-approval"]}
             _ -> {"In Review", []}
           end

         %SymphonyElixir.Linear.Issue{id: id, identifier: identifier, title: "T", state: state, labels: labels}
         |> Map.put(:project_slug, "project")
       end}
    end

    defp project_nodes(slugs), do: for(slug <- slugs, do: %{"slugId" => slug, "name" => "Project " <> slug, "teams" => %{"nodes" => [%{"key" => "PAY"}]}})

    defp member("mia@acme.test"), do: users("Mia", false, ["PAY"])
    defp member("ada@acme.test"), do: users("Ada", true, [])
    defp member(_email), do: {:ok, %{"data" => %{"users" => %{"nodes" => []}}}}

    defp users(name, admin, teams) do
      nodes = Enum.map(teams, &%{"id" => "t-" <> &1, "key" => &1, "name" => &1})
      user = %{"id" => "u-" <> name, "displayName" => name, "admin" => admin, "guest" => false, "active" => true, "teams" => %{"nodes" => nodes}}
      {:ok, %{"data" => %{"users" => %{"nodes" => [user]}}}}
    end

    defp stage_lookup(variables) do
      %{
        "issue" => %{"team" => %{"id" => "t-PAY", "states" => %{"nodes" => [%{"id" => "s"}]}}, "labels" => %{"nodes" => []}},
        "issueLabels" => %{"nodes" => [%{"id" => "l", "name" => variables.stage, "parent" => %{"name" => "factory"}, "team" => %{"id" => "t-PAY"}}]}
      }
    end
  end

  defmodule StubOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      running = %{
        issue_id: "id-PAY-1",
        identifier: "PAY-1",
        issue_title: "Checkout",
        state: "In Review",
        project_slug: "project",
        backend: "claude",
        workspace_path: "/srv/secret/PAY-1",
        session_id: "thread-1",
        turn_count: 3,
        last_agent_message: "working",
        last_agent_timestamp: nil,
        last_agent_event: :notification,
        agent_input_tokens: 4,
        agent_output_tokens: 8,
        agent_total_tokens: 12,
        started_at: DateTime.utc_now()
      }

      retry = %{issue_id: "id-PAY-9", identifier: "PAY-9", backend: "codex", attempt: 2, due_in_ms: 2_000, error: "boom"}
      totals = %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 1}
      {:reply, %{running: [running], retrying: [retry], agent_totals: totals, rate_limits: nil}, state}
    end

    def handle_call(:request_refresh, _from, state), do: {:reply, %{queued: true, requested_at: DateTime.utc_now()}, state}
  end

  setup do
    Auth.clear_cache()
    Users.reset()
    RateLimit.reset()
    McpTokens.reset()
    AgentInbox.reset()
    Transcript.reset()
    Store.reset()
    UsageLedger.reset()
    keys = [:linear_client_module, :fake_linear_recipient]
    saved = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1)})
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinear)
    Application.put_env(:symphony_elixir, :fake_linear_recipient, self())

    on_exit(fn ->
      Auth.clear_cache()
      Users.reset()
      McpTokens.reset()
      AgentInbox.reset()
      Transcript.reset()
      Store.reset()
      UsageLedger.reset()

      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)

      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    write_config!("    enabled: true")
    {:ok, _pid} = StubOrchestrator.start_link(name: @orchestrator)
    config = Keyword.merge(endpoint_config, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: @orchestrator, snapshot_timeout_ms: 200)
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    admin = register!("ada", "ada@acme.test")
    mia = register!("mia", "mia@acme.test")
    %{admin: admin, mia: mia, mia_token: token!(mia), admin_token: token!(admin)}
  end

  describe "watching" do
    test "status summarises sessions and retries without host details", %{mia_token: token} do
      %{"counts" => %{"running" => 1}, "running" => [session], "retrying" => [retry]} = ok!(token, "symphony_status")
      assert %{"issue_identifier" => "PAY-1", "turn_count" => 3, "tokens" => %{"total_tokens" => 12}} = session
      refute Map.has_key?(session, "workspace_path")
      assert %{"issue_identifier" => "PAY-9", "last_message" => "boom"} = retry
    end

    test "issues by flow, stage, and approval; one issue with its session and moves", %{mia_token: token} do
      observe!("PAY-1", "In Review")
      observe!("PAY-3", "In Review")
      observe!("PAY-3", "In Progress", ["factory/merge", "needs-approval"])

      assert %{"count" => 2} = ok!(token, "list_issues")
      assert %{"issues" => [%{"identifier" => "PAY-3", "awaiting_approval" => true, "to" => "merge"}]} = ok!(token, "list_issues", %{"awaiting_approval" => true})
      assert %{"count" => 2} = ok!(token, "list_issues", %{"scope" => "pay", "stage" => "review"})
      assert %{"count" => 0} = ok!(token, "list_issues", %{"scope" => "project:elsewhere"})
      assert %{"count" => 0} = ok!(token, "list_issues", %{"scope" => 5})

      assert %{"session" => %{"issue_identifier" => "PAY-1"}, "stage" => "review", "moves" => []} = ok!(token, "get_issue", %{"identifier" => "pay-1"})

      assert %{"stage" => "merge", "previous_stage" => "review", "awaiting_approval" => true, "moves" => [%{"to" => "merge"}]} =
               ok!(token, "get_issue", %{"identifier" => "PAY-3"})

      assert %{"session" => nil, "stage" => nil, "moves" => []} = ok!(token, "get_issue", %{"identifier" => "PAY-77"})

      assert error!(token, "get_issue", %{"identifier" => "not an id"}) =~ "look like PAY-12"
      assert error!(token, "get_issue", %{"identifier" => 5}) =~ "must be a string"
      assert error!(token, "get_issue", %{}) =~ "required"
    end

    test "transcripts are limited to the newest entries", %{mia_token: token} do
      for n <- 1..3, do: {:ok, _} = AgentInbox.send_message("PAY-1", "note #{n}", "Mia")

      assert %{"total" => 3, "entries" => [%{"text" => text}]} = ok!(token, "get_transcript", %{"identifier" => "PAY-1", "limit" => 1})
      assert text =~ "note 3"
      assert %{"total" => 3} = ok!(token, "get_transcript", %{"identifier" => "PAY-1"})
      assert error!(token, "get_transcript", %{"identifier" => "PAY-1", "limit" => 0}) =~ "positive integer"
      assert error!(token, "get_transcript", %{"identifier" => "WEB-1"}) =~ "not found"
    end

    test "flows: admins read any flow, including projects'", %{admin_token: token} do
      assert %{"scope" => "project:checkout", "inherited" => true} = ok!(token, "get_flow", %{"scope" => "project:checkout"})
    end

    test "an unavailable orchestrator is reported, not crashed on", %{mia_token: token} do
      assert %{"queued" => true} = ok!(token, "refresh")
      GenServer.stop(@orchestrator)
      assert error!(token, "symphony_status") =~ "isn't available"
      assert error!(token, "refresh") =~ "unavailable"
    end
  end

  describe "steering" do
    test "moves and reviews go through the flow's rules and name the token", %{mia_token: token, admin_token: admin_token} do
      observe!("PAY-1", "In Review")

      assert %{"moved" => true} = ok!(token, "move_issue", %{"issue" => "PAY-1", "to" => "merge"})
      assert_receive {:graphql, comment, %{body: body}}, 1_000
      assert comment =~ "SymphonyCreateComment"
      assert body =~ "@mia"
      assert body =~ "via MCP"

      assert error!(token, "move_issue", %{"issue" => "id-PAY-2", "to" => "done"}) =~ "Only admins can force it"
      # A failed comment is logged; the move still counts.
      assert capture_log(fn -> ok!(admin_token, "move_issue", %{"issue" => "id-PAY-2", "to" => "done"}) end) =~ "Move comment failed"
      assert error!(token, "move_issue", %{"issue" => "id-DOWN-1", "to" => "merge"}) =~ "linear_down"
      assert error!(token, "move_issue", %{"issue" => "PAY-404", "to" => "merge"}) =~ "isn't in a project"

      observe!("PAY-3", "In Review")
      observe!("PAY-3", "In Progress", ["factory/merge", "needs-approval"])
      assert %{"reviewed" => true, "verdict" => "approve"} = ok!(token, "review_issue", %{"issue" => "PAY-3", "verdict" => "approve"})
      assert %{"reviewed" => true} = ok!(token, "review_issue", %{"issue" => "id-PAY-3", "verdict" => "send_back"})
      assert error!(token, "review_issue", %{"issue" => "id-PAY-2", "verdict" => "approve"}) =~ "isn't waiting"
      assert error!(token, "review_issue", %{"issue" => "id-PAY-3", "verdict" => "maybe"}) =~ "approve or send_back"
    end

    test "flow edits validate their input", %{mia_token: token, admin_token: admin_token} do
      %{"version" => version, "definition" => definition} = ok!(token, "get_flow", %{"scope" => "PAY"})

      assert error!(token, "save_flow", %{"scope" => "PAY", "base_version" => version, "definition" => %{"stages" => []}}) =~ "isn't valid"
      assert error!(token, "save_flow", %{"scope" => "PAY", "base_version" => "0", "definition" => definition}) =~ "must be an integer"
      assert error!(token, "save_flow", %{"scope" => "PAY", "base_version" => 0, "definition" => []}) =~ "must be an object"
      assert error!(admin_token, "save_flow", %{"scope" => "../x", "base_version" => 0, "definition" => definition}) =~ "valid team"

      # Saving syncs the stage labels in the background; a Linear failure is only logged.
      log =
        capture_log(fn ->
          ok!(token, "save_flow", %{"scope" => "PAY", "base_version" => version, "definition" => definition})
          assert_receive {:graphql, "query SymphonyStageLabels" <> _, _}, 1_000
          Process.sleep(50)
        end)

      assert log =~ "Linear label sync failed"

      control = %{"scope" => "PAY", "stage" => "todo"}
      assert error!(token, "set_stage_control", Map.merge(control, %{"field" => "color", "value" => 1})) =~ "field must be one of"
      assert error!(token, "set_stage_control", Map.put(control, "field", "paused")) =~ "value is required"
      assert error!(token, "set_stage_control", Map.merge(control, %{"field" => "max_agents", "value" => "lots"})) =~ "Invalid max_agents"
      assert error!(token, "set_stage_control", Map.merge(control, %{"stage" => "nowhere", "field" => "paused", "value" => true})) =~ "nowhere"

      assert %{"autopilot" => %{"enabled" => true, "streak" => 3}} = ok!(token, "set_autopilot", %{"scope" => "PAY", "enabled" => true, "streak" => 3})
      assert error!(token, "set_autopilot", %{"scope" => "PAY", "enabled" => "yes", "streak" => 3}) =~ "true or false"
      assert error!(token, "set_autopilot", %{"scope" => "PAY", "enabled" => true, "streak" => 0}) =~ "approvals in a row"
      assert error!(admin_token, "set_autopilot", %{"scope" => "../x", "enabled" => true, "streak" => 3}) =~ "valid team"

      assert %{"reset" => true, "now_uses" => "template"} = ok!(token, "reset_flow", %{"scope" => "PAY"})
      assert error!(admin_token, "reset_flow", %{"scope" => "../x"}) =~ "valid team"
    end

    test "agent messages: too long, or the inbox is down", %{mia_token: token} do
      assert error!(token, "send_agent_message", %{"identifier" => "PAY-1", "text" => String.duplicate("a", 8_001)}) =~ "8000"
      assert error!(token, "send_agent_message", %{"identifier" => "PAY-1", "text" => " "}) =~ "required"

      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, AgentInbox)
      on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, AgentInbox) end)
      assert error!(token, "send_agent_message", %{"identifier" => "PAY-1", "text" => "hi"}) =~ "unavailable"
    end

    test "unknown tools and the error texts", %{mia: mia} do
      {:ok, user} = Auth.user_for_id(mia.id)
      assert {:error, "Unknown tool nope."} = Tools.call("nope", %{}, %{user: user, scopes: ["read"], actor: "mia", via: "via test"})

      reasons = [:not_admin, :invalid_team, :not_team_member, :signed_out, :pending, :state_not_found]

      for reason <- [{:stage_label_not_found, "qa"} | reasons] do
        assert IssueMoves.describe_error(reason) =~ ~r/\w/
      end

      assert IssueMoves.describe_error(:surprise) == ":surprise"
      assert IssueMoves.resolve_id(" abc-uuid ") == "abc-uuid"
    end
  end

  describe "projects Symphony listens to" do
    setup do
      SymphonyElixir.ProjectRoutes.reset()
      on_exit(&SymphonyElixir.ProjectRoutes.reset/0)
    end

    test "admins add and remove projects; members can only look", %{admin_token: admin, mia_token: mia} do
      url = "https://linear.app/acme/project/widgets-0a1b2c3d4e5f/"

      assert %{"added" => %{"slug" => "0a1b2c3d4e5f", "repo" => "acme/widgets", "workflow" => "WORKFLOW.md"}, "note" => note} =
               ok!(admin, "add_project", %{"project" => url, "repo" => "acme/widgets"})

      assert note =~ "WORKFLOW.md on main"
      # Its name and its teams' labels are looked up in Linear in the background.
      assert_receive {:graphql, "query SymphonyProjectTeams" <> _, %{slugs: ["0a1b2c3d4e5f"]}}, 1_000
      assert eventually(fn -> SymphonyElixir.LabelSync.project_names()["0a1b2c3d4e5f"] == "Project 0a1b2c3d4e5f" end)
      assert [%{added_by: "ada via MCP (agent)"}] = SymphonyElixir.ProjectRoutes.list()

      # This test runs Symphony with a single WORKFLOW.md, where stored projects aren't live.
      assert %{"projects" => projects} = ok!(mia, "list_projects")

      assert Enum.any?(projects, &match?(%{"project" => "0a1b2c3d4e5f", "source" => "mcp", "active" => false, "added_by" => "ada via MCP (agent)"}, &1))

      assert error!(mia, "add_project", %{"project" => "abc123def456", "repo" => "acme/app"}) =~ "Only admins"
      assert error!(mia, "remove_project", %{"project" => "0a1b2c3d4e5f"}) =~ "Only admins"

      assert error!(admin, "add_project", %{"project" => "abc123def456", "repo" => "../srv"}) =~ "owner/name"
      assert error!(admin, "add_project", %{"project" => "not a project!", "repo" => "a/b"}) =~ "Linear project URL"

      assert %{"removed" => "0a1b2c3d4e5f"} = ok!(admin, "remove_project", %{"project" => "0a1b2c3d4e5f"})
      assert error!(admin, "remove_project", %{"project" => "0a1b2c3d4e5f"}) =~ "isn't listening"
    end

    test "projects set in the config file can't be changed here; controls off blocks changes", %{admin_token: admin} do
      write_config!("    enabled: true", tracker_projects: [%{slug: "fromfile1"}])
      assert %{"projects" => [%{"project" => "fromfile1", "source" => "config", "active" => true}]} = ok!(admin, "list_projects")
      assert error!(admin, "add_project", %{"project" => "fromfile1", "repo" => "a/b"}) =~ "symphony.yml"
      assert error!(admin, "remove_project", %{"project" => "fromfile1"}) =~ "symphony.yml"

      write_config!("    enabled: true\n  controls: false")
      assert error!(admin, "add_project", %{"project" => "abc123def456", "repo" => "a/b"}) =~ "read-only"
    end
  end

  describe "the manual" do
    test "is a tool, and resources, and the server tells clients to use it", %{mia_token: token} do
      assert %{"manual" => manual, "sections" => sections} = ok!(token, "get_manual")
      assert manual =~ "# Symphony manual"
      assert "using-this-mcp" in sections and "recipes" in sections
      assert %{"manual" => "## Recipes" <> _} = ok!(token, "get_manual", %{"section" => "recipes"})
      assert error!(token, "get_manual", %{"section" => "nope"}) =~ "Sections:"

      rpc = fn method, params ->
        json_response(post_json(token, %{jsonrpc: "2.0", id: 1, method: method, params: params}), 200)
      end

      assert %{"result" => %{"capabilities" => %{"resources" => _}, "instructions" => instructions}} = rpc.("initialize", %{})
      assert instructions =~ "get_manual"

      assert %{"result" => %{"resources" => [%{"uri" => "symphony://manual"} | section_resources]}} = rpc.("resources/list", %{})
      assert length(section_resources) == length(sections)
      assert %{"result" => %{"resourceTemplates" => []}} = rpc.("resources/templates/list", %{})

      assert %{"result" => %{"contents" => [%{"mimeType" => "text/markdown", "text" => ^manual}]}} = rpc.("resources/read", %{uri: "symphony://manual"})
      assert %{"result" => %{"contents" => [%{"text" => "## Overview" <> _}]}} = rpc.("resources/read", %{uri: "symphony://manual/overview"})
      assert %{"error" => %{"code" => -32_002}} = rpc.("resources/read", %{uri: "symphony://manual/nope"})
      assert %{"error" => %{"code" => -32_002}} = rpc.("resources/read", %{uri: "file:///etc/passwd"})
    end
  end

  describe "protocol edges" do
    test "client responses are accepted, malformed messages refused", %{mia_token: token} do
      assert post_json(token, %{jsonrpc: "2.0", id: 1, result: %{}}).status == 202
      assert post_json(token, %{jsonrpc: "2.0", id: 1, error: %{code: 1, message: "x"}}).status == 202
      assert %{"error" => %{"code" => -32_600}} = json_response(post_json(token, %{hello: "world"}), 400)

      ping = post_json(token, %{jsonrpc: "2.0", id: 1, method: "ping"}, [{"mcp-protocol-version", "2025-06-18"}])
      assert %{"result" => %{}} = json_response(ping, 200)

      no_name = post_json(token, %{jsonrpc: "2.0", id: 2, method: "tools/call", params: %{}})
      assert %{"error" => %{"code" => -32_602, "message" => "tools/call needs params.name"}} = json_response(no_name, 200)

      bad_args = post_json(token, %{jsonrpc: "2.0", id: 3, method: "tools/call", params: %{name: "list_flows", arguments: [1]}})
      assert %{"error" => %{"code" => -32_602}} = json_response(bad_args, 200)

      assert McpAuth.init(:x) == :x
    end

    test "without sign-in, /mcp still answers off localhost, and still needs a token" do
      write_config!("    enabled: true", server_host: "127.0.0.1")
      Application.put_env(:symphony_elixir, :enforce_local_host, true)
      on_exit(fn -> Application.put_env(:symphony_elixir, :enforce_local_host, false) end)

      assert json_response(post_json(nil, %{jsonrpc: "2.0", id: 1, method: "ping"}), 401)
      assert build_conn() |> get("/") |> response(421)
    end
  end

  describe "token store" do
    test "saves only hashes, reloads them, and refuses expired or broken records", %{mia: mia} do
      dir = Path.join(System.tmp_dir!(), "mcp-tokens-#{System.unique_integer([:positive])}")
      path = Path.join(dir, "mcp_tokens.json")
      on_exit(fn -> File.rm_rf(dir) end)
      restart_store(path)

      {:ok, secret, token} = McpTokens.create(mia.id, "keeper", ["read"], 7, ["PAY"])
      body = File.read!(path)
      refute body =~ secret
      assert body =~ token.id

      # Use is recorded, at most once a minute.
      McpTokens.touch(token.id, "10.0.0.1")
      McpTokens.touch(token.id, "10.0.0.2")
      :sys.get_state(McpTokens)
      assert [%{last_used_ip: "10.0.0.1"}] = McpTokens.list(mia.id)
      McpTokens.touch("tok_gone", nil)

      expired = %{"hash" => sha("symp_old"), "id" => "tok_old", "account_id" => mia.id, "scopes" => ["read"], "expires_at" => "2020-01-01T00:00:00Z"}
      broken = %{"hash" => sha("symp_broken"), "id" => "tok_broken", "account_id" => mia.id, "expires_at" => "soon"}
      tokens = Jason.decode!(body)["tokens"] ++ [expired, broken, %{"id" => "no-hash"}]
      File.write!(path, Jason.encode!(%{version: 1, tokens: tokens}))
      restart_store(path)

      assert {:ok, %{id: id}} = McpTokens.verify(secret)
      assert id == token.id
      assert {:error, :expired_token} = McpTokens.verify("symp_old")
      assert {:error, :expired_token} = McpTokens.verify("symp_broken")
      assert {:error, :invalid_token} = McpTokens.verify(nil)

      conn = post_json("symp_old", %{jsonrpc: "2.0", id: 1, method: "ping"})
      assert %{"error" => %{"message" => message}} = json_response(conn, 401)
      assert message =~ "expired"

      File.write!(path, "not json")
      assert capture_log(fn -> restart_store(path) end) =~ "MCP token load failed"
      assert McpTokens.list(mia.id) == []

      restart_store("/dev/null/nope/tokens.json")
      assert capture_log(fn -> {:ok, _, _} = McpTokens.create(mia.id, "x", ["read"], 7, ["PAY"]) end) =~ "MCP token save failed"
    end

    test "rejects bad input and other accounts' revokes", %{mia: mia, admin: admin} do
      {:ok, _secret, token} = McpTokens.create(mia.id, "mine", ["read"], 7, ["PAY"])
      assert {:error, :not_found} = McpTokens.revoke(admin.id, token.id)
      assert {:error, :invalid_account} = McpTokens.create(nil, "x", ["read"], 7, ["PAY"])
      assert {:error, :name_required} = McpTokens.create(mia.id, nil, ["read"], 7, ["PAY"])
      assert {:error, :name_too_long} = McpTokens.create(mia.id, String.duplicate("n", 61), ["read"], 7, ["PAY"])
      assert {:error, :invalid_name} = McpTokens.create(mia.id, "bad\nname", ["read"], 7, ["PAY"])
      assert {:error, :invalid_scopes} = McpTokens.create(mia.id, "x", [], 7, ["PAY"])
      assert {:error, :invalid_scopes} = McpTokens.create(mia.id, "x", "read", 7, ["PAY"])
      assert {:error, :invalid_lifetime} = McpTokens.create(mia.id, "x", ["read"], "7", ["PAY"])
    end
  end

  describe "scoping tokens to teams and projects" do
    test "members pick only their teams; only admins can give everything", %{mia: mia, admin: admin} do
      page = session_for(mia) |> get("/account/mcp") |> html_response(200)
      assert page =~ "Team PAY"
      refute page =~ "Everything (admin)"
      assert session_for(admin) |> get("/account/mcp") |> html_response(200) =~ "Everything (admin)"

      for resources <- [["*"], ["WEB"], ["PAY", "project:elsewhere"]] do
        denied = session_for(mia) |> post("/account/mcp-tokens", %{"name" => "x", "days" => "7", "resources" => resources})
        assert html_response(denied, 422) =~ "only give a token teams and projects you work in"
      end

      assert session_for(mia) |> post("/account/mcp-tokens", %{"name" => "x", "days" => "7"}) |> html_response(422) =~ "Pick what the token can reach"
      assert {:error, :invalid_resources} = McpTokens.create(mia.id, "x", ["read"], 7, ["../etc"])
      assert {:error, :invalid_resources} = McpTokens.create(mia.id, "x", ["read"], 7, "PAY")
      assert {:error, :invalid_resources} = McpTokens.create(mia.id, "x", ["read"], 7, Enum.map(1..51, &"T#{&1}"))
      assert {:ok, _, %{resources: ["*"]}} = McpTokens.create(admin.id, "x", ["read"], 7, ["PAY", "*"])
      assert {:ok, _, %{resources: ["PAY", "project:checkout"]}} = McpTokens.create(mia.id, "y", ["read"], 7, [" pay", "project: checkout"])
      assert {:error, :invalid_resources} = McpTokens.create(mia.id, "z", ["read"], 7, [5])
      refute Auth.token_resource_allowed?(nil, "PAY")
    end

    test "an admin's team token loses admin rights and everything outside the team", %{admin: admin} do
      {:ok, secret, _token} = McpTokens.create(admin.id, "pay only", ["read", "write"], 7, ["PAY"])
      observe!("PAY-2", "In Progress", ["factory/merge"])
      observe!("WEB-1", "In Review")

      assert %{"flows" => [%{"key" => "PAY"}]} = ok!(secret, "list_flows")
      assert %{"issues" => [%{"identifier" => "PAY-2"}]} = ok!(secret, "list_issues")
      assert error!(secret, "get_issue", %{"identifier" => "WEB-1"}) =~ "not found"
      assert error!(secret, "get_flow", %{"scope" => "DEFAULT"}) =~ "No flow"
      assert error!(secret, "reset_flow", %{"scope" => "DEFAULT"}) =~ "Only this team's members"
      assert error!(secret, "move_issue", %{"issue" => "id-PAY-2", "to" => "done"}) =~ "Only admins can force it"

      %{"result" => %{"instructions" => instructions}} =
        json_response(post_json(secret, %{jsonrpc: "2.0", id: 1, method: "initialize", params: %{}}), 200)

      assert instructions =~ "limited to PAY"
    end

    test "a project token reaches only that project's issues", %{mia: mia} do
      observe!("PAY-5", "In Review", [], "checkout")
      observe!("PAY-6", "In Review", [], "billing")
      {:ok, secret, _token} = McpTokens.create(mia.id, "checkout", ["read", "write"], 7, ["project:checkout"])

      assert %{"issues" => [%{"identifier" => "PAY-5"}]} = ok!(secret, "list_issues")
      assert %{"identifier" => "PAY-5", "session" => nil} = ok!(secret, "get_issue", %{"identifier" => "PAY-5"})
      assert error!(secret, "get_issue", %{"identifier" => "PAY-6"}) =~ "not found"
      assert %{"sent" => true} = ok!(secret, "send_agent_message", %{"identifier" => "PAY-5", "text" => "hi"})
      assert error!(secret, "send_agent_message", %{"identifier" => "PAY-6", "text" => "hi"}) =~ "not found"
      assert error!(secret, "set_stage_control", %{"scope" => "PAY", "stage" => "todo", "field" => "paused", "value" => true}) =~ "Only this team"
    end

    test "tokens stop working when their owner loses what they were limited to", %{mia: mia} do
      {:ok, everything, _} = McpTokens.create(mia.id, "x", ["read"], 7, ["*"])
      {:ok, web, _} = McpTokens.create(mia.id, "y", ["read"], 7, ["WEB"])

      for secret <- [everything, web] do
        assert %{"error" => %{"message" => message}} = json_response(post_json(secret, %{jsonrpc: "2.0", id: 1, method: "ping"}), 401)
        assert message =~ "no longer has access"
      end
    end
  end

  describe "account page" do
    test "links to the token page and no longer shows the token form", %{mia: mia} do
      page = session_for(mia) |> get("/account") |> html_response(200)
      assert page =~ ~s(href="/account/mcp")
      assert page =~ "Agents and tools connect with"
      refute page =~ "Create token"
      refute page =~ "MCP tokens for agents"
    end

    test "explains errors and hides itself when MCP is off", %{mia: mia} do
      bad = session_for(mia) |> post("/account/mcp-tokens", %{"name" => "", "access" => "read", "days" => "abc"})
      assert html_response(bad, 422) =~ "Give the token a name"
      assert session_for(mia) |> post("/account/mcp-tokens", %{"name" => "x", "resources" => ["PAY"]}) |> html_response(422) =~ "how long"
      assert session_for(mia) |> post("/account/mcp-tokens/tok_nope/revoke") |> html_response(404) =~ "doesn&#39;t exist"

      write_config!(nil)
      refute session_for(mia) |> get("/account") |> html_response(200) =~ "MCP tokens"
      assert session_for(mia) |> get("/account/mcp") |> redirected_to() == "/"
      assert session_for(mia) |> post("/account/mcp-tokens", %{"name" => "x"}) |> redirected_to() == "/"
      assert session_for(mia) |> post("/account/mcp-tokens/tok_x/revoke") |> redirected_to() == "/"
    end

    test "the token page shows tokens and the create form", %{mia: mia} do
      {:ok, _secret, token} = McpTokens.create(mia.id, "existing bot", ["read"], 7, ["PAY"])
      page = session_for(mia) |> get("/account/mcp") |> html_response(200)
      assert page =~ "MCP tokens"
      assert page =~ "existing bot"
      assert page =~ token.hint
      assert page =~ "Create token"
      assert page =~ ~s(href="/account")
    end

    test "the local operator gets a token page when MCP is on" do
      write_config!("    enabled: true", server_host: "127.0.0.1")
      assert build_conn() |> get("/account") |> redirected_to() == "/account/mcp"
      assert build_conn() |> get("/account/mcp") |> html_response(200) =~ "MCP tokens"

      created = build_conn() |> post("/account/mcp-tokens", %{"name" => "ops", "days" => "7", "resources" => ["*"]}) |> html_response(200)
      assert created =~ "shown again"
      assert [%{name: "ops", account_id: "local", resources: ["*"]}] = McpTokens.list("local")

      write_config!(nil, server_host: "127.0.0.1")
      assert build_conn() |> get("/account") |> redirected_to() == "/"
      assert build_conn() |> get("/account/mcp") |> redirected_to() == "/"
    end
  end

  test "server.mcp config: host is normalised, bad hosts rejected" do
    write_config!("    enabled: true\n    host: \"  MCP.Acme.Test \"")
    assert Config.settings!().server.mcp.host == "mcp.acme.test"

    write_config!("    host: \"\"")
    assert Config.settings!().server.mcp.host == nil

    write_config!("    host: \"not a host!\"")
    assert {:error, _reason} = Config.validate!()
  end

  defp ok!(secret, tool, args \\ %{}) do
    %{"result" => %{"isError" => false, "structuredContent" => result}} = json_response(call(secret, tool, args), 200)
    result
  end

  defp error!(secret, tool, args \\ %{}) do
    %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} = json_response(call(secret, tool, args), 200)
    text
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end

  defp call(secret, tool, args), do: post_json(secret, %{jsonrpc: "2.0", id: 1, method: "tools/call", params: %{name: tool, arguments: args}})

  defp post_json(secret, body, headers \\ []) do
    conn = build_conn() |> put_req_header("content-type", "application/json")
    conn = if secret, do: put_req_header(conn, "authorization", "Bearer " <> secret), else: conn
    conn = Enum.reduce(headers, conn, fn {key, value}, acc -> put_req_header(acc, key, value) end)
    post(conn, "/mcp", Jason.encode!(body))
  end

  defp observe!(identifier, state, labels \\ [], project \\ nil) do
    issue = %Issue{id: "id-" <> identifier, identifier: identifier, title: identifier, state: state, labels: labels}
    issue = %{issue | project_slug: project}
    UsageLedger.observe_issue(%{issue | url: "https://linear.app/x/#{identifier}"})
  end

  defp write_config!(mcp, overrides \\ []) do
    base = [server_host: "0.0.0.0", tracker_kind: "linear", tracker_api_token: "server-key"]
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.merge(base, overrides))

    path = Workflow.workflow_file_path()
    content = File.read!(path)
    content = if mcp, do: String.replace(content, "\nserver:\n", "\nserver:\n  mcp:\n#{mcp}\n", global: false), else: content
    File.write!(path, content)
    WorkflowStore.force_reload()
  end

  defp token!(account) do
    resources = if account.username == "ada", do: ["*"], else: ["PAY"]
    {:ok, secret, _token} = McpTokens.create(account.id, "agent", ["read", "write"], 30, resources)
    secret
  end

  defp sha(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

  # Swaps the supervised store for one that persists to `path`.
  defp restart_store(path) do
    case Process.get(:token_store) do
      nil ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, McpTokens)
        on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, McpTokens) end)

      pid ->
        GenServer.stop(pid)
    end

    {:ok, pid} = McpTokens.start_link(path: path)
    Process.put(:token_store, pid)
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
