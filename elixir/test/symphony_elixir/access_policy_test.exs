defmodule SymphonyElixir.AccessPolicyTest do
  @moduledoc """
  Team-scoped access and the read-only global viewer, end to end: the same
  people through the dashboard (LiveView events), the JSON API and MCP, with
  the server refusing what the page would only hide.
  """
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.{AgentInbox, Auth, McpTokens, Policy, Transcript, UsageLedger, Users}
  alias SymphonyElixir.Factory.Store
  alias SymphonyElixirWeb.Mcp.Tools
  alias SymphonyElixirWeb.RateLimit

  @endpoint SymphonyElixirWeb.Endpoint
  @orchestrator Module.concat(__MODULE__, :Orchestrator)

  # ada: Linear admin. tia: Linear member of PAY and WEB, and Symphony admin of
  # PAY. wes: WEB member. vic: global viewer (in no team). nora: in no team.
  defmodule FakeLinear do
    def graphql(query, variables, _opts \\ []) do
      pid = Application.get_env(:symphony_elixir, :fake_linear_recipient)
      if pid, do: send(pid, {:graphql, query, variables})

      cond do
        query =~ "SymphonyMemberByEmail" -> member(String.downcase(variables[:email]))
        query =~ "SymphonyStageLookup" -> {:ok, %{"data" => stage_lookup(variables)}}
        query =~ "SymphonySetStage" -> {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
        query =~ "SymphonyCreateComment" -> {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
        true -> {:ok, %{"data" => %{"teams" => %{"nodes" => []}, "issueLabels" => %{"nodes" => []}}}}
      end
    end

    def fetch_issue_states_by_ids(ids) do
      {:ok,
       for "id-" <> identifier = id <- ids do
         issue = %SymphonyElixir.Linear.Issue{id: id, identifier: identifier, title: "T", state: "In Review", labels: []}
         %{issue | project_slug: "project"}
       end}
    end

    defp member("ada@acme.test"), do: users("Ada", true, [])
    defp member("tia@acme.test"), do: users("Tia", false, ["PAY", "WEB"])
    defp member("wes@acme.test"), do: users("Wes", false, ["WEB"])
    defp member("vic@acme.test"), do: users("Vic", false, [])
    defp member("nora@acme.test"), do: users("Nora", false, [])
    defp member(_email), do: {:ok, %{"data" => %{"users" => %{"nodes" => []}}}}

    defp users(name, admin, teams) do
      nodes = Enum.map(teams, &%{"id" => "t-" <> &1, "key" => &1, "name" => &1})
      user = %{"id" => "u-" <> name, "displayName" => name, "admin" => admin, "guest" => false, "active" => true, "teams" => %{"nodes" => nodes}}
      {:ok, %{"data" => %{"users" => %{"nodes" => [user]}}}}
    end

    defp stage_lookup(variables) do
      %{
        "issue" => %{"team" => %{"id" => "t", "states" => %{"nodes" => [%{"id" => "s"}]}}, "labels" => %{"nodes" => []}},
        "issueLabels" => %{"nodes" => [%{"id" => "l", "name" => variables.stage, "parent" => %{"name" => "factory"}, "team" => %{"id" => "t"}}]}
      }
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
            state: "In Review",
            backend: "claude",
            workspace_path: "/srv/" <> identifier,
            session_id: "sess-" <> identifier,
            turn_count: 1,
            last_agent_message: nil,
            last_agent_timestamp: nil,
            last_agent_event: :notification,
            agent_input_tokens: 1,
            agent_output_tokens: 2,
            agent_total_tokens: 3,
            started_at: DateTime.utc_now()
          }
        end

      totals = %{input_tokens: 100, output_tokens: 200, total_tokens: 300, seconds_running: 9}
      {:reply, %{running: running, retrying: [], agent_totals: totals, rate_limits: nil}, state}
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

    write_workflow_file!(Workflow.workflow_file_path(), server_host: "0.0.0.0", tracker_kind: "linear", tracker_api_token: "server-key")
    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), "\nserver:\n", "\nserver:\n  mcp:\n    enabled: true\n", global: false))
    WorkflowStore.force_reload()

    {:ok, _pid} = StubOrchestrator.start_link(name: @orchestrator)
    config = Keyword.merge(endpoint_config, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: @orchestrator, snapshot_timeout_ms: 200)
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    # ada signs in first: the bootstrap account.
    people = Map.new(~w(ada tia wes vic nora), &{String.to_atom(&1), iap_account!("#{&1}@acme.test")})
    {:ok, _} = Users.set_team_admin(people.tia.id, "PAY", true, "ada")
    {:ok, _} = Users.set_role(people.vic.id, "global_viewer", "ada")

    for identifier <- ["PAY-1", "WEB-1"] do
      issue = %Issue{id: "id-" <> identifier, identifier: identifier, title: identifier, state: "In Review"}
      UsageLedger.observe_issue(%{issue | labels: []})
      {:ok, _} = AgentInbox.send_message(identifier, "note on #{identifier}", "Ada")
    end

    tokens = Map.new(people, fn {name, account} -> {name, token!(account)} end)
    %{people: people, tokens: tokens}
  end

  describe "roles" do
    test "come from Linear and Symphony's grants", %{people: people} do
      roles = Map.new(people, fn {name, account} -> {name, Policy.role(user!(account))} end)
      assert roles == %{ada: :admin, tia: :member, wes: :member, vic: :global_viewer, nora: :member}

      assert Policy.visible_teams(user!(people.vic)) == :all
      assert Policy.visible_teams(user!(people.tia)) == ["PAY", "WEB"]
      assert Policy.visible_teams(user!(people.nora)) == []
      assert Policy.read_only?(user!(people.vic))
      refute Policy.read_only?(user!(people.tia))
    end

    test "admin outranks global viewer: a Linear admin listed as a viewer stays an admin", %{people: people} do
      {:ok, _} = Users.set_role(people.ada.id, "global_viewer", "ada")
      assert Policy.role(user!(people.ada)) == :admin
    end

    test "a team admin administers only their team; members of other teams can't grant", %{people: people} do
      tia = user!(people.tia)
      assert Policy.can?(tia, {:grant, "PAY"})
      refute Policy.can?(tia, {:grant, "WEB"})
      refute Policy.can?(tia, :control)
      assert Policy.can?(tia, :view_users)
      refute Policy.can?(user!(people.wes), {:grant, "WEB"})
      refute Policy.can?(user!(people.wes), :view_users)
    end
  end

  describe "MCP" do
    test "a member sees and acts on their team only", %{tokens: %{wes: wes}} do
      assert %{"running" => [%{"issue_identifier" => "WEB-1"}], "counts" => %{"running" => 1}} = ok!(wes, "symphony_status")
      assert %{"issues" => issues} = ok!(wes, "list_issues")
      assert Enum.map(issues, & &1["identifier"]) == ["WEB-1"]
      assert %{"flows" => flows} = ok!(wes, "list_flows")
      refute Enum.any?(flows, &(&1["key"] == "PAY"))

      assert error!(wes, "get_issue", %{"identifier" => "PAY-1"}) =~ "not found"
      assert error!(wes, "get_transcript", %{"identifier" => "PAY-1"}) =~ "not found"
      assert error!(wes, "get_flow", %{"scope" => "PAY"}) =~ "No flow PAY"
      assert error!(wes, "move_issue", %{"issue" => "PAY-1", "to" => "merge"}) =~ "only move issues from teams"
      assert error!(wes, "review_issue", %{"issue" => "PAY-1", "verdict" => "approve"}) =~ "only move issues from teams"
      assert error!(wes, "send_agent_message", %{"identifier" => "PAY-1", "text" => "hi"}) =~ "not found"
      assert error!(wes, "set_stage_control", %{"scope" => "PAY", "stage" => "review", "field" => "paused", "value" => true}) =~ "members"
      assert error!(wes, "reset_flow", %{"scope" => "PAY"}) =~ "members"

      # Their own team works.
      assert %{"identifier" => "WEB-1"} = ok!(wes, "get_issue", %{"identifier" => "WEB-1"})
      assert %{"moved" => true} = ok!(wes, "move_issue", %{"issue" => "WEB-1", "to" => "merge"})
      assert %{"sent" => true} = ok!(wes, "send_agent_message", %{"identifier" => "WEB-1", "text" => "hi"})
    end

    test "the global viewer sees every team and every write tool is refused", %{tokens: %{vic: vic}} do
      assert %{"running" => running} = ok!(vic, "symphony_status")
      assert Enum.map(running, & &1["issue_identifier"]) == ["PAY-1", "WEB-1"]
      assert %{"count" => 2} = ok!(vic, "list_issues")
      assert %{"identifier" => "PAY-1"} = ok!(vic, "get_issue", %{"identifier" => "PAY-1"})
      assert %{"total" => 1} = ok!(vic, "get_transcript", %{"identifier" => "WEB-1"})
      assert %{"scope" => "PAY"} = ok!(vic, "get_flow", %{"scope" => "PAY"})

      write_args = %{
        "save_flow" => %{"scope" => "PAY", "base_version" => 0, "definition" => %{}},
        "set_stage_control" => %{"scope" => "PAY", "stage" => "review", "field" => "paused", "value" => true},
        "set_autopilot" => %{"scope" => "PAY", "enabled" => true, "streak" => 3},
        "reset_flow" => %{"scope" => "PAY"},
        "move_issue" => %{"issue" => "PAY-1", "to" => "merge"},
        "review_issue" => %{"issue" => "PAY-1", "verdict" => "approve"},
        "send_agent_message" => %{"identifier" => "PAY-1", "text" => "hi"},
        "refresh" => %{},
        "add_project" => %{"project" => "abc123def456", "repo" => "a/b"},
        "remove_project" => %{"project" => "abc123def456"}
      }

      assert Enum.sort(Map.keys(write_args)) == Enum.sort(Tools.scopes()["write"])

      for {tool, args} <- write_args do
        assert error!(vic, tool, args) =~ "read-only", "#{tool} was not refused"
      end

      # Nothing changed, nothing reached Linear's write endpoints.
      refute_received {:graphql, "mutation" <> _, _}
      assert [_] = AgentInbox.messages("PAY-1")
      assert Store.get("PAY")["inherited"]

      # tools/list offers them only the reading tools.
      %{"result" => %{"tools" => tools}} = json_response(rpc(vic, "tools/list"), 200)
      assert Enum.sort(Enum.map(tools, & &1["name"])) == Enum.sort(Tools.scopes()["read"])
    end

    test "the global admin can do everything", %{tokens: %{ada: ada}} do
      assert %{"count" => 2} = ok!(ada, "list_issues")
      assert %{"moved" => true} = ok!(ada, "move_issue", %{"issue" => "PAY-1", "to" => "merge"})
      assert %{"sent" => true} = ok!(ada, "send_agent_message", %{"identifier" => "WEB-1", "text" => "hi"})
      assert %{"queued" => true} = ok!(ada, "refresh")
      assert %{"scope" => "PAY", "controls" => %{"paused" => true}} = ok!(ada, "set_stage_control", %{"scope" => "PAY", "stage" => "implement", "field" => "paused", "value" => true})
    end

    test "someone in no team sees nothing team-specific", %{tokens: %{nora: nora}} do
      assert %{"running" => [], "counts" => %{"running" => 0}} = ok!(nora, "symphony_status")
      assert %{"count" => 0} = ok!(nora, "list_issues")
      assert %{"projects" => []} = ok!(nora, "list_projects")
      assert error!(nora, "get_issue", %{"identifier" => "WEB-1"}) =~ "not found"
      assert error!(nora, "move_issue", %{"issue" => "WEB-1", "to" => "merge"}) =~ "only move issues from teams"
      # The manual is still theirs.
      assert %{"manual" => _} = ok!(nora, "get_manual")
    end
  end

  describe "dashboard" do
    test "a member's page shows only their team, and other teams' actions are refused", %{people: people} do
      {:ok, view, html} = live(iap_conn(people.wes), "/")
      assert html =~ "WEB-1"
      refute html =~ ~r/PAY-1\b/

      render_hook(view, "factory_move", %{"id" => "id-PAY-1", "to" => "merge"})
      assert_reply(view, %{ok: false, error: "You can only move issues from teams" <> _})

      render_hook(view, "factory_control", %{"team" => "PAY", "stage" => "review", "field" => "paused", "value" => true})
      assert_reply(view, %{ok: false, error: "Only this team's members" <> _})

      render_hook(view, "factory_move", %{"id" => "id-WEB-1", "to" => "merge"})
      assert_reply(view, %{ok: true})
    end

    test "the global viewer sees every team and every change is refused", %{people: people} do
      {:ok, view, html} = live(iap_conn(people.vic), "/")
      assert html =~ "PAY-1"
      assert html =~ "WEB-1"
      assert html =~ "Global viewer"

      events = [
        {"factory_move", %{"id" => "id-PAY-1", "to" => "merge"}},
        {"approve_issue", %{"id" => "id-PAY-1"}},
        {"send_back_issue", %{"id" => "id-PAY-1"}},
        {"factory_control", %{"team" => "PAY", "stage" => "review", "field" => "paused", "value" => true}},
        {"factory_autopilot", %{"team" => "PAY", "enabled" => true, "streak" => 2}},
        {"send_message", %{"text" => "hi"}},
        {"some_future_event", %{}}
      ]

      for {event, params} <- events do
        render_hook(view, event, params)
        assert_reply(view, %{ok: false, error: "Your access is read-only" <> _})
      end

      refute_received {:graphql, "mutation" <> _, _}
      assert Store.get("PAY")["inherited"]

      # Looking around still works.
      render_hook(view, "open_chat", %{"id" => "PAY-1"})
      assert render(view) =~ "note on PAY-1"
    end

    test "the global admin acts on any team", %{people: people} do
      {:ok, view, _html} = live(iap_conn(people.ada), "/")
      render_hook(view, "factory_move", %{"id" => "id-PAY-1", "to" => "merge"})
      assert_reply(view, %{ok: true})
    end

    test "someone in no team sees no team's work", %{people: people} do
      {:ok, _view, html} = live(iap_conn(people.nora), "/")
      refute html =~ ~r/PAY-1\b/
      refute html =~ ~r/WEB-1\b/
    end

    test "Users page: global viewers look, team admins grant their team only, members are turned away", %{people: people} do
      {:ok, view, html} = live(iap_conn(people.vic), "/admin/users")
      assert html =~ "tia@acme.test"
      refute html =~ "+ Add access"
      refute html =~ ">Disable<"

      render_hook(view, "grant", %{"account" => people.wes.id, "choice" => "access:PAY"})
      assert_reply(view, %{ok: false, error: "Your access is read-only" <> _})
      render_hook(view, "disable", %{"id" => people.wes.id})
      assert_reply(view, %{ok: false})
      assert Users.get(people.wes.id).access == []
      assert Users.get(people.wes.id).status == "active"

      {:ok, view, _html} = live(iap_conn(people.tia), "/admin/users")
      render_hook(view, "grant", %{"account" => people.wes.id, "choice" => "access:PAY"})
      render_hook(view, "grant", %{"account" => people.nora.id, "choice" => "access:WEB"})
      render_hook(view, "grant", %{"account" => people.nora.id, "choice" => "role:global_viewer"})
      render_hook(view, "disable", %{"id" => people.nora.id})
      assert Users.get(people.wes.id).access == ["PAY"]
      assert Users.get(people.nora.id).access == []
      assert Users.get(people.nora.id).role == nil
      assert Users.get(people.nora.id).status == "active"

      assert {:error, {:redirect, %{to: "/"}}} = live(iap_conn(people.wes), "/admin/users")

      # Admins make people global viewers.
      {:ok, view, _html} = live(iap_conn(people.ada), "/admin/users")
      render_hook(view, "grant", %{"account" => people.nora.id, "choice" => "role:global_viewer"})
      assert Users.get(people.nora.id).role == "global_viewer"
      render_hook(view, "revoke", %{"id" => people.nora.id, "choice" => "role:global_viewer"})
      assert Users.get(people.nora.id).role == nil
    end
  end

  describe "JSON API and pages" do
    test "the global viewer reads everything and changes nothing, but rotates their own token", %{people: people} do
      vic = iap_conn(people.vic)
      payload = vic |> get("/api/v1/state") |> json_response(200)
      assert Enum.map(payload["running"], & &1["issue_identifier"]) == ["PAY-1", "WEB-1"]
      assert get(iap_conn(people.vic), "/metrics").status == 200

      assert %{"error" => %{"code" => "forbidden"}} = json_response(post(iap_conn(people.vic), "/api/v1/refresh"), 403)
      assert json_response(post(iap_conn(people.vic), "/api/v1/restart"), 403)

      message = iap_conn(people.vic) |> put_req_header("content-type", "application/json") |> post("/api/v1/issues/PAY-1/messages", ~s({"text":"hi"}))
      assert json_response(message, 403)
      assert [_] = AgentInbox.messages("PAY-1")

      # Self-service: their own MCP token.
      {:ok, before, _token} = McpTokens.current(people.vic.id)
      assert iap_conn(people.vic) |> post("/account/mcp-token/rotate") |> html_response(200) =~ "New token issued"
      {:ok, rotated, _token} = McpTokens.current(people.vic.id)
      assert rotated != before
    end

    test "members get their teams' state and spend only, and no Prometheus metrics", %{people: people} do
      payload = iap_conn(people.wes) |> get("/api/v1/state") |> json_response(200)
      assert Enum.map(payload["running"], & &1["issue_identifier"]) == ["WEB-1"]
      # Symphony-wide totals would show other teams' spend.
      assert payload["agent_totals"]["total_tokens"] == 3
      assert json_response(get(iap_conn(people.wes), "/api/v1/PAY-1"), 404)
      assert json_response(get(iap_conn(people.wes), "/metrics"), 403)

      message = iap_conn(people.wes) |> put_req_header("content-type", "application/json") |> post("/api/v1/issues/PAY-1/messages", ~s({"text":"hi"}))
      assert json_response(message, 404)
    end
  end

  describe "sign-in" do
    test "a provisioned account may sign in without a Linear user; others may not" do
      assert {:error, :not_in_workspace} = Auth.user_for_email("zed@acme.test")
      assert Users.get_by_email("zed@acme.test") == nil

      {:ok, [_]} = Users.provision([{"zed@acme.test", %{role: :keep, team_admin: [], access: ["PAY"]}}], "ada")
      assert {:ok, %Auth.User{teams: [%{key: "PAY"}]} = zed} = Auth.user_for_email("ZED@acme.test")
      assert Policy.visible_teams(zed) == ["PAY"]
    end
  end

  defp user!(account) do
    {:ok, user} = Auth.user_for_id(account.id)
    user
  end

  defp token!(account) do
    {:ok, secret, _token} = McpTokens.current(account.id)
    secret
  end

  defp ok!(secret, tool, args \\ %{}) do
    %{"result" => %{"isError" => false, "structuredContent" => result}} = json_response(call(secret, tool, args), 200)
    result
  end

  defp error!(secret, tool, args) do
    %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} = json_response(call(secret, tool, args), 200)
    text
  end

  defp call(secret, tool, args), do: rpc(secret, "tools/call", %{name: tool, arguments: args})

  defp rpc(secret, method, params \\ %{}) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> secret)
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
  end
end
