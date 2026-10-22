defmodule SymphonyElixir.TeamsOverviewTest do
  @moduledoc """
  Teams Symphony knows without projects (added by an admin or the accounts
  import), the default flow they follow, and the overview across teams by
  Linear state: scoped by `SymphonyElixir.Policy`, and never showing an issue
  without the opt-in label.
  """
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.{Auth, McpTokens, Policy, Teams, UsageLedger, Users}
  alias SymphonyElixir.Factory.{Definition, Store}
  alias SymphonyElixir.Users.Import
  alias SymphonyElixirWeb.{FactoryPresenter, Overview, RateLimit}

  @endpoint SymphonyElixirWeb.Endpoint
  @orchestrator Module.concat(__MODULE__, :Orchestrator)

  # ada: Linear admin. tia: PAY and WEB member, Symphony admin of PAY. wes: WEB
  # member. vic: global viewer. Linear's key sees PAY, WEB and OPS, not SEC.
  defmodule FakeLinear do
    @states %{
      "PAY" => [{"Todo", "unstarted", 1}, {"In Progress", "started", 2}, {"In Review", "started", 3}, {"Done", "completed", 4}],
      "WEB" => [{"Todo", "unstarted", 1}, {"Building", "started", 2}, {"QA", "started", 3}, {"Shipped", "completed", 4}],
      "OPS" => [{"Backlog", "backlog", 0}, {"Todo", "unstarted", 1}, {"Done", "completed", 4}]
    }

    def graphql(query, variables, _opts \\ []) do
      pid = Application.get_env(:symphony_elixir, :fake_linear_recipient)
      if pid, do: send(pid, {:graphql, query, variables})

      cond do
        query =~ "SymphonyMemberByEmail" -> member(String.downcase(variables[:email]))
        query =~ "SymphonyTeamsLookup" -> {:ok, %{"data" => %{"teams" => %{"nodes" => lookup(variables)}}}}
        true -> {:ok, %{"data" => %{"teams" => %{"nodes" => []}, "issueLabels" => %{"nodes" => []}}}}
      end
    end

    defp lookup(%{ids: ids, keys: keys}) do
      for {key, states} <- @states, ("t-" <> String.downcase(key)) in ids or key in keys do
        nodes = for {name, type, position} <- states, do: %{"name" => name, "type" => type, "position" => position}
        %{"id" => "t-" <> String.downcase(key), "key" => key, "name" => key <> " team", "states" => %{"nodes" => nodes}}
      end
    end

    defp member("ada@acme.test"), do: users("Ada", true, [])
    defp member("tia@acme.test"), do: users("Tia", false, ["PAY", "WEB"])
    defp member("wes@acme.test"), do: users("Wes", false, ["WEB"])
    defp member("vic@acme.test"), do: users("Vic", false, [])
    defp member(_email), do: {:ok, %{"data" => %{"users" => %{"nodes" => []}}}}

    defp users(name, admin, teams) do
      nodes = Enum.map(teams, &%{"id" => "t-" <> String.downcase(&1), "key" => &1, "name" => &1})
      user = %{"id" => "u-" <> name, "displayName" => name, "admin" => admin, "guest" => false, "active" => true, "teams" => %{"nodes" => nodes}}
      {:ok, %{"data" => %{"users" => %{"nodes" => [user]}}}}
    end
  end

  defmodule StubOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, opts}

    # An agent works on PAY-1, and still on WEB-2, which just lost its label.
    def handle_call(:snapshot, _from, state) do
      running =
        for identifier <- ["PAY-1", "WEB-2"] do
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

      totals = %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      {:reply, %{running: running, retrying: [], agent_totals: totals, rate_limits: nil}, state}
    end
  end

  setup do
    Auth.clear_cache()
    Users.reset()
    RateLimit.reset()
    McpTokens.reset()
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
      Store.reset()
      UsageLedger.reset()
      Teams.reset()

      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)

      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      server_host: "0.0.0.0",
      tracker_kind: "linear",
      tracker_api_token: "server-key",
      tracker_require_label: "auto-build"
    )

    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), "\nserver:\n", "\nserver:\n  mcp:\n    enabled: true\n", global: false))
    WorkflowStore.force_reload()

    {:ok, _pid} = StubOrchestrator.start_link(name: @orchestrator)
    config = Keyword.merge(endpoint_config, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: @orchestrator, snapshot_timeout_ms: 200)
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    people = Map.new(~w(ada tia wes vic), &{String.to_atom(&1), iap_account!("#{&1}@acme.test")})
    {:ok, _} = Users.set_team_admin(people.tia.id, "PAY", true, "ada")
    {:ok, _} = Users.set_role(people.vic.id, "global_viewer", "ada")

    %{people: people}
  end

  # Issues as the poll reads them. WEB's flow uses its own state names
  # (Building, QA); WEB-2 lacks the opt-in label.
  defp track_issues do
    rename = %{"In Progress" => "Building", "In Review" => "QA"}
    web = Map.update!(Definition.default_template(), "stages", fn stages -> Enum.map(stages, &Map.update!(&1, "linear_state", fn s -> rename[s] || s end)) end)
    {:ok, _} = Store.put("WEB", web, 0, "wes")

    for {identifier, state, type, labels} <- [
          {"PAY-1", "In Review", "started", ["auto-build"]},
          {"PAY-2", "Todo", "unstarted", ["Auto-Build"]},
          {"WEB-1", "QA", "started", ["ai/auto-build"]},
          {"WEB-2", "Building", "started", ["bug"]},
          {"OPS-1", "Done", "completed", ["auto-build"]}
        ] do
      issue = %Issue{
        id: "id-" <> identifier,
        identifier: identifier,
        title: "Task " <> identifier,
        state: state,
        state_type: type,
        labels: labels,
        url: "https://linear.app/x/" <> identifier
      }

      UsageLedger.observe_issue(issue, external: true)
    end
  end

  describe "teams and the default flow" do
    test "a team added in Symphony follows the default flow until it gets its own" do
      {:ok, [%{key: "OPS"}]} = Teams.register([%{key: "ops", name: "Operations"}], "ada")

      # No default saved yet: the built-in flow.
      assert %{"source" => "template", "inherited" => true} = Store.get("OPS")
      assert Store.get("OPS")["stages"] == Definition.default_template()["stages"]

      default = Map.put(Definition.default_template(), "transitions", tl(Definition.default_template()["transitions"]))
      {:ok, saved} = Store.put("DEFAULT", default, 0, "ada")
      assert %{"source" => "DEFAULT", "inherited" => true} = Store.get("OPS")
      assert Store.get("OPS")["transitions"] == saved["transitions"]

      # The team's own flow overrides the default; the default no longer reaches it.
      {:ok, _own} = Store.put("OPS", Definition.default_template(), 0, "tia")
      assert %{"source" => "OPS", "inherited" => false} = Store.get("OPS")
      {:ok, _} = Store.put("DEFAULT", Definition.default_template(), saved["version"], "ada")
      assert Store.get("OPS")["source"] == "OPS"

      # Teams that are only known (no work, no flow) are on offer, after the default.
      payload = FactoryPresenter.payload([], Config.settings!())
      assert [%{key: "DEFAULT", kind: "default", name: "Default flow"}, %{key: "OPS", kind: "team", name: "Operations"}] = payload.teams
      assert payload.team == "OPS"
    end

    test "the importer adds the teams it names through Linear and grants them, with no errors", %{people: people} do
      csv = """
      email,linear_team_name,linear_team_id,role
      pia@acme.test,Payments,t-pay,member
      pia@acme.test,Ops,t-ops,admin
      quinn@acme.test,Ops,t-ops,member
      tia@acme.test,Payments,t-pay,admin
      """

      assert {:ok, dry} = Import.from_csv(csv, dry_run: true)
      assert %{errors: [], teams: 2, teams_added: ["OPS", "PAY"], written: false} = dry
      assert Teams.list() == []

      assert {:ok, report} = Import.from_csv(csv)
      assert %{errors: [], teams: 2, teams_added: ["OPS", "PAY"], written: true, created: 2} = report
      assert %{key: "OPS", id: "t-ops", name: "OPS team", added_by: "import", states: [_ | _] = states} = Teams.get("OPS")
      assert %{name: "Backlog", type: "backlog"} = hd(Enum.sort_by(states, & &1.position))
      assert %{access: ["PAY"], team_admin: ["OPS"]} = Users.get_by_email("pia@acme.test")
      assert %{access: ["OPS"]} = Users.get_by_email("quinn@acme.test")
      assert "PAY" in Users.get(people.tia.id).team_admin

      # A new team follows the default flow, and a member of it sees it.
      assert Store.get("OPS")["inherited"]
      {:ok, quinn} = Auth.user_for_email("quinn@acme.test")
      assert Policy.visible_teams(quinn) == ["OPS"]

      # Known teams aren't looked up again.
      flush_graphql()
      assert {:ok, %{errors: [], teams_added: [], unchanged: 3, written: false}} = Import.from_csv(csv)
      refute_received {:graphql, "query SymphonyTeamsLookup" <> _, _}
    end

    test "a team Linear's key can't see is named by its linear_team_key column, else reported" do
      csv = """
      email,linear_team_name,linear_team_id,role,linear_team_key
      sam@acme.test,Security,t-sec,member,
      pia@acme.test,Web,t-web,member,
      """

      assert {:ok, %{errors: [%{line: 2, reason: reason}], written: false, teams_added: ["WEB"]}} = Import.from_csv(csv)
      assert reason =~ "unknown Linear team id t-sec: Symphony's Linear API key can't see that team"
      assert Teams.list() == []

      with_key = String.replace(csv, "t-sec,member,", "t-sec,member,sec")
      assert {:ok, %{errors: [], written: true, teams_added: ["SEC", "WEB"]}} = Import.from_csv(with_key)
      assert %{key: "SEC", name: "Security", id: "t-sec", states: []} = Teams.get("SEC")
      assert %{access: ["SEC"]} = Users.get_by_email("sam@acme.test")
    end

    test "only admins edit the default flow; team admins edit their team's", %{people: people} do
      [ada, tia, wes, vic] = Enum.map([people.ada, people.tia, people.wes, people.vic], &user!/1)

      assert Policy.can?(ada, {:edit_flow, "DEFAULT"})
      assert Policy.authorize(vic, {:edit_flow, "DEFAULT"}) == {:error, :read_only}
      assert Policy.authorize(tia, {:edit_flow, "DEFAULT"}) == {:error, :not_admin}
      assert Policy.authorize(tia, {:edit_flow, "default"}) == {:error, :not_admin}
      assert Policy.authorize(wes, {:edit_flow, "DEFAULT"}) == {:error, :not_admin}
      assert Policy.can?(tia, {:edit_flow, "PAY"})
      refute Policy.can?(wes, {:edit_flow, "PAY"})

      # The same over MCP, where flows are edited; the dashboard only shows them.
      template = Definition.default_template()
      assert error!(token!(people.tia), "save_flow", %{"scope" => "DEFAULT", "base_version" => 0, "definition" => template}) =~ "Only admins"
      assert error!(token!(people.vic), "save_flow", %{"scope" => "DEFAULT", "base_version" => 0, "definition" => template}) =~ "read-only"
      refute Store.custom?("DEFAULT")
      assert %{"version" => 1} = ok!(token!(people.ada), "save_flow", %{"scope" => "DEFAULT", "base_version" => 0, "definition" => template})
      assert Store.custom?("DEFAULT")

      {:ok, _view, html} = live(iap_conn(people.ada), "/?flow=default")
      assert html =~ "Every team without its own flow follows this one"
      assert html =~ "save_flow"

      # The MCP button opens the setup popup, for read-only people too.
      {:ok, view, _html} = live(iap_conn(people.vic), "/")
      render_hook(view, "open_mcp_setup", %{})
      assert_reply(view, %{ok: true})
      assert render(view) =~ "mcp-welcome-title"
    end

    test "admins add a team on the Users page; global viewers see the list only", %{people: people} do
      {:ok, view, _html} = live(iap_conn(people.ada), "/admin/users")
      html = view |> form("#add-team", %{"team" => "web, NOPE"}) |> render_submit()
      assert html =~ "Added WEB"
      assert html =~ "Linear didn&#39;t return NOPE"
      assert %{key: "WEB", name: "WEB team"} = Teams.get("WEB")
      assert html =~ "Building · QA"

      {:ok, _view, html} = live(iap_conn(people.vic), "/admin/users")
      assert html =~ "WEB team"
      refute html =~ "add-team"
    end
  end

  describe "overview" do
    setup do
      track_issues()
      :ok
    end

    test "groups issues by Linear state across teams, filters by team, and hides unlabeled issues" do
      rows = FactoryPresenter.payload([], Config.settings!()).overview
      refute Enum.any?(rows, &(&1.issue == "WEB-2"))

      overview = Overview.build(rows)
      assert overview.total == 4
      assert Enum.map(overview.columns, & &1.label) == ["Todo", "In progress", "Done"]
      started = Enum.find(overview.columns, &(&1.type == "started"))
      assert Enum.map(started.states, &{&1.name, &1.teams}) |> Enum.sort() == [{"In Review", %{"PAY" => 1}}, {"QA", %{"WEB" => 1}}]
      assert %{key: "PAY", total: 2, counts: %{"started" => 1, "unstarted" => 1}} = Enum.find(overview.teams, &(&1.key == "PAY"))

      web = Overview.build(rows, teams: ["WEB"])
      assert web.total == 1
      assert [%{states: [%{name: "QA", issues: [%{issue: "WEB-1", stage_name: "In Review"}]}]}] = web.columns
    end

    test "a type's rarer state names fold into one Other stage, named on its caption" do
      states = ["In Progress", "In Review", "QA", "Staging", "Canary", "In Progress", "In Review", "QA", "Staging", "Canary", "Verify", "Soak"]

      rows =
        for {state, i} <- Enum.with_index(states) do
          %{issue: "T#{i}-1", title: "t", url: nil, team: "T#{i}", project: nil, state: state, state_type: "started"}
          |> Map.merge(%{stage: "x", stage_name: "x", since_ms: i, running: false, awaiting: false})
        end

      %{definition: %{"stages" => stages}, flow: %{nodes: nodes}} = Overview.flow(rows)
      names = Enum.map(stages, & &1["name"])
      assert ["Backlog", "Todo", "In Progress", "In Review" | _] = names
      assert Enum.take(names, -3) == ["Other in progress", "Done", "Canceled"]
      assert Enum.sort(Enum.slice(names, 4, 3)) == ["Canary", "QA", "Staging"]
      assert %{"label" => label} = Enum.find(stages, &(&1["id"] == "other-started"))
      assert label in ["Verify · Soak", "Soak · Verify"]
      assert nodes["other-started"].count == 2
      assert Enum.all?(Enum.chunk_every(stages, 2, 1, :discard), fn [a, b] -> a["position"]["x"] <= b["position"]["x"] or b["kind"] == "parked" end)
    end

    test "with all teams picked, a global viewer's flow is Linear states across teams, read-only", %{people: people} do
      {:ok, _view, html} = live(iap_conn(people.vic), "/")
      assert html =~ "Flow · all teams by Linear state"
      # The pickers are drawn as the dashboard's own dropdowns over the native selects.
      assert html =~ ~s(data-dropdown-slot="team-picker-dd")
      assert html =~ ~s(id="team-picker-dd")
      factory = factory_data(html)
      assert factory["scope"] == "overview"
      assert %{"kind" => "overview"} = hd(factory["teams"])
      refute factory["can_edit"]["overview"]
      refute Map.has_key?(factory, "overview")

      stages = factory["definitions"]["overview"]["stages"]
      names = Enum.map(stages, & &1["name"])
      # Linear's usual states in order, each team's own names alongside.
      assert ["Backlog", "Todo", "In Progress", "In Review", "QA", "Done", "Canceled"] = names
      assert %{"label" => "WEB"} = Enum.find(stages, &(&1["name"] == "QA"))

      nodes = factory["flows"]["overview"]["nodes"]
      issues = for {_id, node} <- nodes, issue <- node["issues"], do: issue["issue"]
      assert Enum.sort(issues) == ["OPS-1", "PAY-1", "PAY-2", "WEB-1"]
      assert %{"count" => 1, "running" => 1, "issues" => [%{"issue" => "PAY-1", "backend" => "claude", "team" => "PAY"}]} = nodes["started-in-review"]

      # Picking a team shows that team's own flow, not the Linear-state one.
      {:ok, _view, html} = live(iap_conn(people.vic), "/?team=WEB")
      factory = factory_data(html)
      assert factory["scope"] == "WEB"
      refute Enum.any?(factory["teams"], &(&1["kind"] == "overview"))
      assert Enum.any?(factory["definitions"]["WEB"]["stages"], &(&1["linear_state"] == "QA"))
    end

    test "it covers only the viewer's teams; someone in one team sees that team's flow", %{people: people} do
      {:ok, _view, html} = live(iap_conn(people.tia), "/")
      factory = factory_data(html)
      assert factory["scope"] == "overview"
      issues = for {_id, node} <- factory["flows"]["overview"]["nodes"], issue <- node["issues"], do: issue["issue"]
      assert Enum.sort(issues) == ["PAY-1", "PAY-2", "WEB-1"]

      {:ok, _view, html} = live(iap_conn(people.wes), "/")
      factory = factory_data(html)
      refute factory["scope"] == "overview"
      refute Enum.any?(factory["teams"], &(&1["kind"] == "overview"))
      refute html =~ ~r/PAY-1\b/
      refute html =~ ~r/WEB-2\b/
    end

    test "MCP: status counts by Linear state for the caller's teams; unlabeled issues are found nowhere", %{people: people} do
      vic = token!(people.vic)
      assert %{"overview" => %{"total" => 4, "by_state_type" => by_type, "by_team" => by_team}, "running" => running} = ok!(vic, "symphony_status")
      assert Enum.map(running, & &1["issue_identifier"]) == ["PAY-1"]
      assert %{"count" => 2, "states" => states} = Enum.find(by_type, &(&1["state_type"] == "started"))
      assert Enum.sort(Enum.map(states, & &1["name"])) == ["In Review", "QA"]
      assert Enum.map(by_team, & &1["key"]) |> Enum.sort() == ["OPS", "PAY", "WEB"]

      assert %{"overview" => %{"total" => 1}} = ok!(vic, "symphony_status", %{"teams" => ["web"]})
      assert %{"overview" => %{"total" => 1, "by_team" => [%{"key" => "WEB"}]}} = ok!(token!(people.wes), "symphony_status")

      ada = token!(people.ada)
      assert %{"issues" => issues} = ok!(ada, "list_issues")
      refute Enum.any?(issues, &(&1["identifier"] == "WEB-2"))
      assert %{"state" => "QA", "state_type" => "started", "team" => "WEB"} = Enum.find(issues, &(&1["identifier"] == "WEB-1"))
      assert %{"issues" => [%{"identifier" => "PAY-2"}]} = ok!(ada, "list_issues", %{"state_type" => "unstarted"})
      assert %{"count" => 1} = ok!(ada, "list_issues", %{"team" => "web"})

      assert error!(ada, "get_issue", %{"identifier" => "WEB-2"}) =~ "not found"
      assert error!(ada, "get_transcript", %{"identifier" => "WEB-2"}) =~ "not found"
      assert %{"identifier" => "WEB-1"} = ok!(ada, "get_issue", %{"identifier" => "WEB-1"})
    end

    test "an issue that gets the label shows up; one that loses it disappears" do
      assert UsageLedger.hidden?("WEB-2")
      issue = %Issue{id: "id-WEB-2", identifier: "WEB-2", title: "Task WEB-2", state: "Building", state_type: "started", labels: ["auto-build"]}
      UsageLedger.observe_issue(issue, external: true)
      refute UsageLedger.hidden?("WEB-2")
      assert Enum.any?(UsageLedger.snapshot().flow.issues, &(&1.issue == "WEB-2"))

      UsageLedger.observe_issue(%{issue | labels: []}, external: true)
      assert UsageLedger.hidden?("WEB-2")
      refute Enum.any?(UsageLedger.snapshot().flow.issues, &(&1.issue == "WEB-2"))
    end
  end

  describe "quick links and removing projects" do
    setup do
      SymphonyElixir.ProjectRoutes.reset()
      SymphonyElixirWeb.QuickLinks.reset()

      on_exit(fn ->
        SymphonyElixir.ProjectRoutes.reset()
        SymphonyElixirWeb.QuickLinks.reset()
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        server_host: "0.0.0.0",
        tracker_kind: "linear",
        tracker_api_token: "server-key",
        tracker_require_label: "auto-build",
        tracker_projects: [%{slug: "checkout", repo: "acme/checkout", repos: [%{repo: "acme/checkout-docs", name: "docs"}]}]
      )

      path = Workflow.workflow_file_path()
      File.write!(path, String.replace(File.read!(path), "\nserver:\n", "\nserver:\n  mcp:\n    enabled: true\n", global: false))
      WorkflowStore.force_reload()

      issue = %Issue{
        id: "id-PAY-7",
        identifier: "PAY-7",
        title: "Checkout totals",
        state: "Todo",
        state_type: "unstarted",
        labels: ["auto-build"],
        project_slug: "checkout",
        url: "https://linear.app/acme/issue/PAY-7/checkout-totals"
      }

      UsageLedger.observe_issue(issue, external: true)
      %{issue: issue}
    end

    test "a picked team or project links to its Linear page and its repos", %{people: people} do
      {:ok, _view, html} = live(iap_conn(people.vic), "/?team=PAY")
      assert html =~ "https://linear.app/acme/team/PAY/active"
      assert html =~ "https://github.com/acme/checkout"
      assert html =~ "https://github.com/acme/checkout-docs"

      {:ok, _view, html} = live(iap_conn(people.vic), "/?team=PAY&project=checkout")
      assert html =~ "https://linear.app/acme/project/checkout"
      assert html =~ "https://github.com/acme/checkout-docs"

      # All teams: the workspace, and no repos.
      {:ok, _view, html} = live(iap_conn(people.vic), "/")
      assert html =~ ~s(href="https://linear.app/acme")
      refute html =~ "github.com/acme/checkout"

      # Someone who can't see the project gets none of its links.
      {:ok, _view, html} = live(iap_conn(people.wes), "/")
      refute html =~ "github.com/acme/checkout"
    end

    test "admins and the project's team admins remove a project; it stays gone", %{people: people, issue: issue} do
      [tia, wes, vic] = Enum.map([people.tia, people.wes, people.vic], &user!/1)
      assert Policy.can?(tia, {:remove_project, "checkout"})
      assert Policy.authorize(wes, {:remove_project, "checkout"}) == {:error, :not_team_admin}
      assert Policy.authorize(vic, {:remove_project, "checkout"}) == {:error, :read_only}
      assert error!(token!(people.wes), "remove_project", %{"project" => "checkout"}) =~ "teams you administer"
      assert error!(token!(people.vic), "remove_project", %{"project" => "checkout"}) =~ "read-only"

      {:ok, _view, html} = live(iap_conn(people.vic), "/?team=PAY&project=checkout")
      refute html =~ "Remove project"
      {:ok, view, html} = live(iap_conn(people.tia), "/?team=PAY&project=checkout")
      assert html =~ "Remove project"
      assert html =~ "Remove checkout from Symphony?"

      {:ok, _} = Store.put("project:checkout", Definition.default_template(), 0, "tia")
      render_click(view, "remove_project", %{"project" => "checkout"})
      assert_patch(view, "/?team=PAY")

      assert SymphonyElixir.ProjectRoutes.removed?("checkout")
      refute Store.custom?("project:checkout")
      refute Enum.any?(Config.linear_project_routes(), &(&1.slug == "checkout"))
      refute Enum.any?(FactoryPresenter.payload([], Config.settings!()).teams, &(&1[:slug] == "checkout"))

      # The next poll reads its issue again: still not listed, history kept.
      UsageLedger.observe_issue(issue, external: true)
      refute Enum.any?(FactoryPresenter.payload([], Config.settings!()).teams, &(&1[:slug] == "checkout"))
      assert Map.has_key?(UsageLedger.projects(), "checkout")
      {:ok, _view, html} = live(iap_conn(people.tia), "/?team=PAY&project=checkout")
      refute html =~ ~s(<option value="checkout")

      # Admins bring it back over MCP.
      assert %{"restored" => "checkout"} = ok!(token!(people.ada), "add_project", %{"project" => "checkout", "repo" => "acme/checkout"})
      assert Enum.any?(Config.linear_project_routes(), &(&1.slug == "checkout"))
    end
  end

  defp factory_data(html) do
    [json] = html |> Floki.parse_document!() |> Floki.attribute("#factory-data", "data-json")
    Jason.decode!(json)
  end

  defp flush_graphql do
    receive do
      {:graphql, _query, _variables} -> flush_graphql()
    after
      0 -> :ok
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

  defp rpc(secret, method, params) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> secret)
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
  end
end
