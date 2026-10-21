defmodule SymphonyElixir.FactoryEditorTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{Auth, FactoryControls, IssueStage, SessionHistory, Tracker, UsageLedger, Users}
  alias SymphonyElixir.Factory.{Definition, StagePrompt, Store}
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixirWeb.{FactoryPresenter, Visibility}

  @endpoint SymphonyElixirWeb.Endpoint
  @password "correct horse battery"

  defmodule LabelLinear do
    def graphql(query, variables, _opts \\ []) do
      send(Application.get_env(:symphony_elixir, :fake_linear_recipient), {:graphql, query, variables})

      cond do
        query =~ "SymphonyStageLabels" ->
          Process.get(:inventory) || {:ok, Application.get_env(:symphony_elixir, :fake_inventory)}

        query =~ "SymphonyCreateLabel" ->
          Application.get_env(:symphony_elixir, :fake_create, {:ok, %{"data" => %{"issueLabelCreate" => %{"success" => true, "issueLabel" => %{"id" => "new-" <> variables.input.name}}}}})

        query =~ "SymphonyMemberByEmail" ->
          member(variables.email)

        query =~ "SymphonyStageLookup" ->
          {:ok, %{"data" => stage_lookup(variables)}}

        query =~ "SymphonySetStage" ->
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}

        query =~ "SymphonyCreateComment" ->
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
      end
    end

    def fetch_issue_states_by_ids(ids) do
      {:ok,
       for id <- ids, String.starts_with?(id, "id-") do
         identifier = String.replace_prefix(id, "id-", "")

         labels =
           case identifier do
             "PAY-2" -> ["factory/merge"]
             "PAY-3" -> ["factory/merge", "needs-approval"]
             _ -> []
           end

         state = if identifier in ["PAY-2", "PAY-3"], do: "In Progress", else: "In Review"

         %SymphonyElixir.Linear.Issue{
           id: id,
           identifier: identifier,
           title: "T",
           state: state,
           labels: labels,
           project_slug: "project"
         }
       end}
    end

    defp member("mia@acme.test"), do: users("Mia", false, ["PAY"])
    defp member("ada@acme.test"), do: users("Ada", true, [])
    defp member(_email), do: {:ok, %{"data" => %{"users" => %{"nodes" => []}}}}

    defp users(name, admin, teams) do
      nodes = Enum.map(teams, &%{"id" => "t-" <> &1, "key" => &1, "name" => &1 <> " team"})

      user = %{
        "id" => "u-" <> name,
        "displayName" => name,
        "admin" => admin,
        "guest" => false,
        "active" => true,
        "teams" => %{"nodes" => nodes}
      }

      {:ok, %{"data" => %{"users" => %{"nodes" => [user]}}}}
    end

    defp stage_lookup(variables) do
      %{
        "issue" => %{
          "team" => %{"id" => "t-PAY", "states" => %{"nodes" => [%{"id" => "s"}]}},
          "labels" => %{"nodes" => [%{"id" => "keep", "name" => "bug"}, %{"id" => "appr", "name" => "Needs-Approval"}]}
        },
        "issueLabels" => %{"nodes" => [%{"id" => "l", "name" => variables.stage, "parent" => %{"name" => "factory"}, "team" => %{"id" => "t-PAY"}}]}
      }
    end
  end

  defmodule StubOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, opts}

    # Tests set running agents with :sys.replace_state/2; :snapshots counts the calls.
    def handle_call(:snapshot, _from, state) do
      totals = %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      state = Keyword.update(state, :snapshots, 1, &(&1 + 1))
      {:reply, %{running: Keyword.get(state, :running, []), retrying: [], agent_totals: totals, rate_limits: nil}, state}
    end

    def handle_call(:request_refresh, _from, state), do: {:reply, %{queued: true}, state}
  end

  setup do
    Store.reset()
    Users.reset()
    UsageLedger.reset()
    Auth.clear_cache()
    # Project names and teams a label sync learned.
    :persistent_term.erase({SymphonyElixir.LabelSync, :project_names})
    :persistent_term.erase({SymphonyElixir.LabelSync, :project_teams})
    keys = [:linear_client_module, :fake_linear_recipient, :fake_inventory, :fake_create]
    saved = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1)})
    Application.put_env(:symphony_elixir, :linear_client_module, LabelLinear)
    Application.put_env(:symphony_elixir, :fake_linear_recipient, self())

    on_exit(fn ->
      Store.reset()
      Users.reset()
      UsageLedger.reset()
      Auth.clear_cache()

      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", tracker_api_token: "server-key")
    :ok
  end

  defp inventory(nodes, team_id \\ "t-PAY") do
    Application.put_env(:symphony_elixir, :fake_inventory, %{
      "data" => %{"teams" => %{"nodes" => if(team_id, do: [%{"id" => team_id}], else: [])}, "issueLabels" => %{"nodes" => nodes}}
    })
  end

  describe "label sync" do
    test "creates the stage group and missing stage labels for the team" do
      inventory([%{"id" => "x", "name" => "merge", "isGroup" => false, "team" => nil, "parent" => %{"id" => "other"}}])

      assert {:ok, ["factory", "factory/merge", "factory/qa"]} = Adapter.ensure_stage_labels("PAY", ["merge", "QA", "qa"])
      assert_received {:graphql, _, %{input: %{name: "factory", isGroup: true, teamId: "t-PAY"}}}
      assert_received {:graphql, _, %{input: %{name: "merge", parentId: "new-factory", teamId: "t-PAY"}}}
    end

    test "reuses the team's group, else a workspace-wide one, and skips labels that exist" do
      group = %{"id" => "g-team", "name" => "Factory", "isGroup" => true, "team" => %{"id" => "t-PAY"}, "parent" => nil}
      workspace = %{"id" => "g-ws", "name" => "factory", "isGroup" => true, "team" => nil, "parent" => nil}
      existing = %{"id" => "l1", "name" => "Merge", "isGroup" => false, "team" => %{"id" => "t-PAY"}, "parent" => %{"id" => "g-team"}}

      inventory([workspace, group, existing])
      assert {:ok, ["factory/qa"]} = Adapter.ensure_stage_labels("PAY", ["merge", "qa"])

      inventory([workspace])
      assert {:ok, ["factory/merge"]} = Adapter.ensure_stage_labels("PAY", ["merge"])
      assert_received {:graphql, _, %{input: %{name: "merge", parentId: "g-ws"}}}
    end

    test "reports unknown teams and failed creates" do
      inventory([], nil)
      assert {:error, :team_not_found} = Adapter.ensure_stage_labels("NOPE", ["merge"])

      inventory([])
      Application.put_env(:symphony_elixir, :fake_create, {:ok, %{"data" => %{"issueLabelCreate" => %{"success" => false}}}})
      assert {:error, {:label_create_failed, "factory"}} = Adapter.ensure_stage_labels("PAY", ["merge"])

      group = %{"id" => "g", "name" => "factory", "isGroup" => true, "team" => %{"id" => "t-PAY"}, "parent" => nil}
      inventory([group])
      Application.put_env(:symphony_elixir, :fake_create, {:error, :boom})
      assert {:error, :boom} = Adapter.ensure_stage_labels("PAY", ["merge"])
    end

    test "the memory tracker records the request" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      assert {:ok, []} = Tracker.ensure_stage_labels("PAY", ["qa"])
      assert_received {:memory_tracker_ensure_labels, "PAY", ["qa"]}
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end
  end

  describe "definition details" do
    test "skills are stored at the stage's own path and reach the prompt" do
      definition = Definition.default_template()
      stages = Enum.map(definition["stages"], &if(&1["id"] == "merge", do: Map.put(&1, "skill", %{"path" => "/etc/x", "content" => "Use the merge queue."}), else: &1))
      {:ok, _} = Store.put("PAY", %{definition | "stages" => stages}, 0, "mia")

      assert Definition.stage(Store.get("PAY"), "merge")["skill"] == %{"path" => ".codex/skills/merge/SKILL.md", "content" => "Use the merge queue."}
      issue = %Issue{id: "i", identifier: "PAY-1", state: "In Progress", labels: ["factory/merge"]}
      assert StagePrompt.render(issue) =~ "### Skill for this stage (.codex/skills/merge/SKILL.md)\n\nUse the merge queue."
    end

    test "custom teams add their dispatch states to polling, and controls list agent stages" do
      definition = Definition.default_template()
      qa = %{"id" => "qa", "name" => "QA", "kind" => "agent", "linear_state" => "QA", "label" => nil}
      {:ok, _} = Store.put("PAY", %{definition | "stages" => definition["stages"] ++ [qa]}, 0, "mia")

      assert "QA" in IssueStage.active_state_names()
      assert Map.keys(FactoryControls.all("PAY")) |> Enum.sort() == ["implement", "merge", "qa", "rework", "todo"]
      # No team: the organisation default flow.
      assert Map.keys(FactoryControls.all()) |> Enum.sort() == ["implement", "merge", "rework", "todo"]
    end

    test "guests and signed-out users can't edit any flow" do
      guest = %Auth.User{id: "g", name: "g", guest: true, teams: [%{id: "t", key: "PAY", name: "P"}]}
      refute Auth.can_edit_factory?(guest, "PAY")
      refute Auth.can_edit_factory?(nil, "PAY")
      refute Auth.can_edit_factory?(%Auth.User{id: "m", name: "m", teams: []}, nil)
    end

    test "a project's own flow wins over its team's, which wins over the default" do
      template = Definition.default_template()
      qa = %{"id" => "qa", "name" => "QA", "kind" => "agent", "linear_state" => "QA", "label" => nil}
      {:ok, _} = Store.put("DEFAULT", template, 0, "ada")
      {:ok, _} = Store.put("project:checkout", %{template | "stages" => template["stages"] ++ [qa]}, 0, "mia")

      in_project = %Issue{id: "1", identifier: "PAY-1", state: "QA", project_slug: "checkout"}
      elsewhere = %Issue{in_project | project_slug: "web"}

      assert IssueStage.flow_scope(in_project) == "project:checkout"
      assert IssueStage.control_stage(in_project) == {"project:checkout", "qa"}
      assert IssueStage.flow_scope(elsewhere) == "PAY"
      assert IssueStage.stage(elsewhere) == nil
      assert "QA" in IssueStage.active_state_names()

      # Views say which flow they came from.
      assert %{"team" => "project:web", "source" => "DEFAULT", "inherited" => true} = Store.get("project:web", "PAY")
      {:ok, _} = Store.put("PAY", template, 0, "mia")
      assert %{"source" => "PAY"} = Store.get("project:web", "PAY")
      assert %{"source" => "project:checkout", "inherited" => false} = Store.get(" project:checkout ")
      assert Store.projects() == ["checkout"]
      assert Store.teams() == ["DEFAULT", "PAY"]
      assert Store.project_scope("bad slug") == nil
      assert Store.project_scope(nil) == nil
      assert Store.scope_for("PAY", nil) == "PAY"
    end

    test "the presenter lists projects with their teams, and their own issues and loops" do
      template = Definition.default_template()
      {:ok, _} = Store.put("project:checkout", template, 0, "mia")

      for {id, project, journey} <- [{"PAY-1", "checkout", ["Todo", "In Progress", "In Review"]}, {"PAY-2", "web", ["Todo", "In Progress"]}, {"WEB-1", "web", ["Todo"]}] do
        Enum.each(journey, &UsageLedger.observe_issue(%Issue{id: id, identifier: id, title: id, state: &1, project_slug: project}))
      end

      web = %Issue{identifier: "WEB-1", project_slug: "web", project_name: "Web App"}
      UsageLedger.record_tokens(%{issue: web, backend: "claude"}, %{input_tokens: 1, output_tokens: 1})

      payload = FactoryPresenter.payload([], Config.settings!())
      projects = Enum.filter(payload.teams, &(&1.kind == "project"))

      assert [%{key: "project:checkout", name: "checkout", teams: ["PAY"], custom: true}, %{key: "project:web", name: "Web App", teams: ["PAY", "WEB"], custom: false}] =
               Enum.map(projects, &Map.take(&1, [:key, :name, :teams, :custom]))

      # Configured projects are listed even before they have work.
      write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: nil, tracker_projects: [%{slug: "fresh"}])
      assert "project:fresh" in Enum.map(FactoryPresenter.payload([], Config.settings!()).teams, & &1.key)

      # A project without its own flow shows its main team's (here PAY's, inherited from the default).
      assert %{"source" => "template", "team" => "project:web"} = payload.definitions["project:web"]
      assert payload.flows["project:checkout"].edges == %{"todo>implement" => 1, "implement>review" => 1}
      assert payload.flows["project:checkout"].nodes["review"].count == 1
      # PAY's own diagram leaves out the issue that follows the project's flow.
      assert payload.flows["PAY"].nodes["review"].count == 0
      assert payload.flows["PAY"].edges == %{"todo>implement" => 1}
      assert payload.flows["project:web"].nodes["todo"].count == 1
    end

    test "members edit the flows of projects their teams work in; viewers see only their teams' issues" do
      mia = %Auth.User{id: "m", name: "m", teams: [%{id: "t", key: "PAY", name: "P"}]}
      Enum.each(["Todo", "In Progress"], &UsageLedger.observe_issue(%Issue{id: "1", identifier: "PAY-1", state: &1, project_slug: "shared"}))
      UsageLedger.observe_issue(%Issue{id: "2", identifier: "WEB-1", state: "In Progress", project_slug: "shared"})
      UsageLedger.observe_issue(%Issue{id: "3", identifier: "WEB-2", state: "Todo", project_slug: "web-only"})

      assert Auth.can_edit_factory?(mia, "project:shared")
      refute Auth.can_edit_factory?(mia, "project:web-only")

      factory = FactoryPresenter.payload([], Config.settings!())
      payload = Visibility.filter_payload(%{running: [], retrying: [], projects: [], factory: factory}, mia)
      assert Enum.map(payload.factory.teams, & &1.key) == ["PAY", "project:shared"]
      assert payload.factory.team == "PAY"
      assert %{count: 1, issues: [%{issue: "PAY-1"}]} = payload.factory.flows["project:shared"].nodes["implement"]

      # Someone given only the project sees all of its work, and nothing else.
      lee = %Auth.User{id: "l", name: "l", teams: [], projects: ["shared"]}
      running = [%{issue_identifier: "WEB-1", project_slug: "shared"}, %{issue_identifier: "WEB-2", project_slug: "web-only"}]
      projects = [%{slug: "shared", issues: [%{issue_identifier: "WEB-1"}]}, %{slug: "web-only", issues: [%{issue_identifier: "WEB-2"}]}]
      payload = Visibility.filter_payload(%{running: running, retrying: [], projects: projects, factory: factory}, lee)
      assert Enum.map(payload.running, & &1.issue_identifier) == ["WEB-1"]
      assert [%{issues: [_]}, %{issues: []}] = payload.projects
      assert Enum.map(payload.factory.teams, & &1.key) == ["project:shared"]
      assert payload.factory.team == nil
      assert payload.factory.flows["project:shared"].nodes["implement"].count == 2
    end

    test "approval stages: the flag is kept, held issues pause, and the prompt says how to hand off" do
      template = Definition.default_template()
      stages = Enum.map(template["stages"], &if(&1["id"] == "implement", do: Map.put(&1, "approval", true), else: &1))
      {:ok, saved} = Store.put("PAY", %{template | "stages" => stages}, 0, "mia")
      assert Definition.stage(saved, "implement")["approval"] == true
      assert Definition.stage(saved, "merge")["approval"] == false

      issue = %Issue{id: "i", identifier: "PAY-7", state: "In Progress", labels: ["factory/implement"]}
      held = %{issue | labels: ["factory/implement", "Needs-Approval"]}
      refute IssueStage.awaiting_approval?(issue)
      assert IssueStage.awaiting_approval?(held)
      refute IssueStage.awaiting_approval?(nil)
      assert IssueStage.paused?(held)
      refute IssueStage.paused?(issue)

      prompt = StagePrompt.render(issue)
      assert prompt =~ "### Hand-off between stages"
      assert prompt =~ "Code travels on the branch `symphony/PAY-7`"
      assert prompt =~ "Your summary is the hand-off"
      assert prompt =~ "posts your summary on the issue as `## Implement`"
      assert prompt =~ "A person approves the move before the next stage starts"

      # A normal stage still makes its own moves.
      refute StagePrompt.render(%{issue | labels: ["factory/merge"]}) =~ "A person approves the move"

      # The ledger notices the approval flag without counting a transition.
      UsageLedger.observe_issue(issue)
      UsageLedger.observe_issue(held)
      assert [%{issue: "PAY-7", awaiting_approval: true}] = UsageLedger.snapshot().flow.issues
      assert UsageLedger.snapshot().flow.edges == []
      payload = FactoryPresenter.payload([], Config.settings!())
      assert [%{awaiting: true}] = payload.flows["PAY"].nodes["implement"].issues
      assert payload.approval_label == "needs-approval"
    end

    test "the presenter shows the default flow when no team has work or a flow yet" do
      payload = FactoryPresenter.payload([], Config.settings!())
      assert payload.teams == [%{key: "DEFAULT", kind: "default", name: "Default flow", custom: false}]
      assert payload.definitions["DEFAULT"]["stages"] |> length() == 7
    end
  end

  describe "editor events" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(),
        server_host: "0.0.0.0",
        tracker_kind: "linear",
        tracker_api_token: "server-key",
        agent_backend: "claude"
      )

      name = Module.concat(__MODULE__, :Orchestrator)
      {:ok, _pid} = StubOrchestrator.start_link(name: name)

      config =
        :symphony_elixir
        |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
        |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: name, snapshot_timeout_ms: 200)

      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
      start_supervised!({SymphonyElixirWeb.Endpoint, []})

      ada_params = %{"username" => "ada", "email" => "ada@acme.test", "password" => @password, "setup_code" => Users.setup_code()}
      {:ok, ada} = Users.register(ada_params, &Auth.check_linear_member/1)
      mia_params = %{"username" => "mia", "email" => "mia@acme.test", "password" => @password}
      {:ok, mia} = Users.register(mia_params, &Auth.check_linear_member/1)
      {:ok, mia} = Users.approve(mia.id, "ada")
      inventory([])
      SessionHistory.reset()
      on_exit(fn -> SessionHistory.reset() end)
      %{ada: ada, mia: mia, orchestrator: name}
    end

    # An orchestrator snapshot's running entry.
    defp running_agent(identifier, project, opts \\ []) do
      %{
        issue_id: "id-" <> identifier,
        identifier: identifier,
        issue_title: Keyword.get(opts, :title, "Work on " <> identifier),
        issue_url: nil,
        state: "In Progress",
        project_slug: project,
        labels: [],
        backend: "claude",
        session_id: "s-" <> identifier,
        turn_count: 2,
        started_at: Keyword.get(opts, :started_at, DateTime.utc_now()),
        last_agent_timestamp: Keyword.get(opts, :last_at),
        last_agent_message: nil,
        last_agent_event: nil,
        agent_input_tokens: 100,
        agent_output_tokens: 20,
        agent_total_tokens: 120
      }
    end

    defp set_running(orchestrator, running), do: :sys.replace_state(orchestrator, &Keyword.put(&1, :running, running))

    defp data_json(html) do
      [_, json] = Regex.run(~r/data-json="([^"]*)"/, html)
      json |> String.replace("&quot;", "\"") |> String.replace("&amp;", "&") |> String.replace("&#39;", "'") |> Jason.decode!()
    end

    defp session_for(account),
      do: build_conn() |> Plug.Test.init_test_session(%{"user_id" => account.id, "session_version" => Users.get(account.id).session_version})

    test "members save their own team's flow; conflicts and invalid flows are reported", %{mia: mia} do
      {:ok, view, html} = live(session_for(mia), "/")
      assert html =~ "factory_flow.js?v="

      draft = Store.get("PAY") |> Map.update!("stages", &(&1 ++ [%{"id" => "qa", "name" => "QA", "kind" => "agent", "linear_state" => "In Progress", "label" => "qa"}]))
      render_hook(view, "factory_save", %{"team" => "PAY", "version" => 0, "definition" => draft})
      assert_reply(view, %{ok: true, definition: %{"version" => 1, "updated_by" => "mia"}})

      # Labels are synced to Linear in the background.
      assert_receive {:graphql, _, %{input: %{name: "qa", parentId: "new-factory"}}}, 1_000

      render_hook(view, "factory_save", %{"team" => "PAY", "version" => 0, "definition" => draft})
      assert_reply(view, %{ok: false, conflict: %{"version" => 1}})

      render_hook(view, "factory_save", %{"team" => "PAY", "version" => 1, "definition" => %{"stages" => []}})
      assert_reply(view, %{ok: false, errors: ["a factory needs at least one stage"]})

      render_hook(view, "factory_save", %{"team" => "WEB", "version" => 0, "definition" => draft})
      assert_reply(view, %{ok: false, errors: ["Only this team's members and Linear admins can change its flow."]})

      render_hook(view, "factory_save", %{"team" => "../x", "version" => 0, "definition" => draft})
      assert_reply(view, %{ok: false, errors: [_]})
    end

    test "moves follow the team's connections; agent-only moves need an admin", %{mia: mia, ada: ada} do
      {:ok, view, _html} = live(session_for(mia), "/")

      # PAY-1 is In Review: review -> merge is a person move.
      render_hook(view, "factory_move", %{"id" => "id-PAY-1", "to" => "merge"})
      assert_reply(view, %{ok: true})

      render_hook(view, "factory_move", %{"id" => "id-PAY-1", "to" => "done"})
      assert_reply(view, %{ok: false, error: "That move isn't a connection in this team's flow."})

      render_hook(view, "factory_move", %{"id" => "id-PAY-1", "to" => "nowhere"})
      assert_reply(view, %{ok: false, error: "That stage isn't in this team's flow."})

      # PAY-2 is in Merge: merge -> done is an agent move.
      render_hook(view, "factory_move", %{"id" => "id-PAY-2", "to" => "done"})
      assert_reply(view, %{ok: false, error: "Agents make that move. Only admins can force it."})

      {:ok, admin_view, _html} = live(session_for(ada), "/")
      render_hook(admin_view, "factory_move", %{"id" => "id-PAY-2", "to" => "done"})
      assert_reply(admin_view, %{ok: true})
    end

    test "people approve or send back a held issue, and stages earn autonomy", %{mia: mia} do
      {:ok, _} = Store.put("PAY", Definition.default_template(), 0, "mia")
      {:ok, _} = Store.put_autopilot("PAY", true, 2, "mia")
      review = fn -> Definition.stage(Store.get("PAY"), "review") end
      # Agent stages need approval until they earn it; person stages never do.
      assert Definition.requires_approval?(Store.get("PAY"), Definition.stage(Store.get("PAY"), "merge"))
      refute Definition.requires_approval?(Store.get("PAY"), review.())

      # The agent moved PAY-3 from review to merge and asked for approval.
      held = %Issue{id: "id-PAY-3", identifier: "PAY-3", title: "Held", state: "In Progress", labels: ["factory/merge", "needs-approval"], url: "https://linear.app/acme/issue/PAY-3"}
      UsageLedger.observe_issue(%{held | state: "In Review", labels: []})
      UsageLedger.observe_issue(held)
      assert UsageLedger.previous_node("PAY-3") == "review"
      assert UsageLedger.previous_node("PAY-404") == nil

      # On the diagram it waits in the stage it's leaving, pointing where it goes.
      flow = FactoryPresenter.payload([], Config.settings!()).flows["PAY"]
      assert [%{issue: "PAY-3", awaiting: true, to: "merge"}] = flow.nodes["review"].issues
      assert flow.nodes["merge"].issues == []

      {:ok, view, html} = live(session_for(mia), "/")
      assert html =~ "Waiting for your approval"
      assert html =~ "In Review → <strong>Merge</strong>"
      assert html =~ ~s(href="https://linear.app/acme/issue/PAY-3")

      view |> element(~s(button[phx-click="approve_issue"])) |> render_click()
      assert_receive {:graphql, query, %{labelIds: label_ids}} when is_binary(query), 1_000
      assert "keep" in label_ids
      refute "appr" in label_ids
      assert review.()["approval_streak"] == 1

      render_hook(view, "send_back_issue", %{"id" => "id-PAY-3"})
      assert review.()["approval_streak"] == 0

      # The agent moves it to merge again; two approvals in a row and the stage stops asking.
      UsageLedger.observe_issue(held)
      render_hook(view, "approve_issue", %{"id" => "id-PAY-3"})
      render_hook(view, "approve_issue", %{"id" => "id-PAY-3"})
      assert review.()["approval_streak"] == 2

      # Errors: not held, unknown origin, unknown issue.
      render_hook(view, "approve_issue", %{"id" => "id-PAY-2"})
      assert render(view) =~ "isn&#39;t waiting for approval any more"
      UsageLedger.reset()
      render_hook(view, "send_back_issue", %{"id" => "id-PAY-3"})
      assert render(view) =~ "doesn&#39;t know which stage that came from"
      render_hook(view, "approve_issue", %{"id" => "not-an-issue"})
      assert render(view) =~ "isn&#39;t in a project this Symphony manages"
    end

    test "the bell lists approvals and the chat panel shows an issue's transcript", %{mia: mia} do
      template = Definition.default_template()
      stages = Enum.map(template["stages"], &if(&1["id"] == "review", do: Map.put(&1, "approval", true), else: &1))
      {:ok, _} = Store.put("PAY", %{template | "stages" => stages}, 0, "mia")
      held = %Issue{id: "id-PAY-3", identifier: "PAY-3", title: "Held", state: "In Progress", labels: ["factory/merge", "needs-approval"]}
      UsageLedger.observe_issue(%{held | state: "In Review", labels: []})
      UsageLedger.observe_issue(held)
      SymphonyElixir.Transcript.note("PAY-3", "Symphony moved the issue to Merge.")
      on_exit(&SymphonyElixir.Transcript.reset/0)

      {:ok, view, html} = live(session_for(mia), "/")
      assert html =~ ~s(class="bell-count numeric")
      refute html =~ "bell-panel"
      assert render_click(view, "toggle_bell", %{}) =~ "bell-panel"
      assert render_click(view, "close_bell", %{}) |> then(&(not (&1 =~ "bell-panel")))

      html = render_click(view, "open_chat", %{"id" => "PAY-3"})
      assert html =~ "chat-panel"
      assert html =~ "Symphony moved the issue to Merge."
      refute render_click(view, "close_chat", %{}) =~ "chat-panel"

      # Issues the viewer can't see don't open.
      refute render_click(view, "open_chat", %{"id" => "WEB-9"}) =~ "chat-panel"
    end

    test "teams turn earned autonomy on and set the streak", %{mia: mia} do
      {:ok, view, _html} = live(session_for(mia), "/")
      render_hook(view, "factory_autopilot", %{"team" => "PAY", "enabled" => true, "streak" => 5})
      assert_reply(view, %{ok: true, definition: %{"autopilot" => %{"enabled" => true, "streak" => 5}}})

      render_hook(view, "factory_autopilot", %{"team" => "PAY", "enabled" => true, "streak" => 0})
      assert_reply(view, %{ok: false, error: "approvals in a row must be a whole number from 1 to 100"})

      render_hook(view, "factory_autopilot", %{"team" => "WEB", "enabled" => true, "streak" => 5})
      assert_reply(view, %{ok: false, error: "Only this team's members" <> _})

      assert {:error, {:unknown_stage, "nope"}} = Store.record_review("PAY", "nope", :approved, "mia")
      assert {:error, :invalid_team} = Store.put_autopilot("bad team!", true, 3, "mia")
      # Stages marked for approval always ask.
      definition = Store.get("PAY")
      assert Definition.requires_approval?(definition, %{"approval" => true})
      refute Definition.requires_approval?(definition, nil)
      assert Definition.autopilot(%{}) == %{"enabled" => false, "streak" => Definition.default_streak()}
    end

    test "members change their own team's stage controls", %{mia: mia} do
      {:ok, view, _html} = live(session_for(mia), "/")
      render_hook(view, "factory_control", %{"team" => "PAY", "stage" => "merge", "field" => "max_agents", "value" => 2})
      assert_reply(view, %{ok: true, controls: %{max_agents: 2}})
      assert FactoryControls.get({"PAY", "merge"}).max_agents == 2
      assert Store.custom?("PAY")

      # The diagram's right-click menu toggles approval the same way.
      render_hook(view, "factory_control", %{"team" => "PAY", "stage" => "merge", "field" => "approval", "value" => true})
      assert_reply(view, %{ok: true})
      assert Definition.stage(Store.get("PAY"), "merge")["approval"] == true
      assert %{"codex" => _, "claude" => _, "opencode" => _} = FactoryPresenter.payload([], Config.settings!()).harness_models
    end

    test "whole flows are drafted with AI for teams and projects, and project flows can be dropped", %{mia: mia} do
      bin = Path.join(System.tmp_dir!(), "symphony-editor-flow-#{System.unique_integer([:positive])}")
      File.mkdir_p!(bin)
      template = Definition.default_template()
      flow = Jason.encode!(%{"summary" => "Same flow.", "stages" => template["stages"], "transitions" => template["transitions"]})
      File.write!(Path.join(bin, "claude"), "#!/bin/sh\nprintf '%s' '#{flow}'\n")
      File.chmod!(Path.join(bin, "claude"), 0o755)
      path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> path)
      UsageLedger.observe_issue(%Issue{id: "1", identifier: "PAY-1", state: "Todo", project_slug: "checkout"})
      checkout = %Issue{identifier: "PAY-1", project_slug: "checkout", project_name: "Checkout"}
      UsageLedger.record_tokens(%{issue: checkout, backend: "claude"}, %{input_tokens: 1, output_tokens: 0})

      try do
        {:ok, view, _html} = live(session_for(mia), "/")
        render_hook(view, "factory_assist_flow", %{"team" => "project:checkout", "request" => "Keep it simple.", "definition" => Store.get("project:checkout", "PAY")})
        assert_reply(view, %{ok: true, pending: true, ref: ref})
        assert_push_event(view, "factory_assist_result", %{ref: ^ref, ok: true, suggestion: suggestion}, 5_000)
        assert %{summary: "Same flow.", changes: %{added: [], removed: []}} = suggestion

        render_hook(view, "factory_assist_flow", %{"team" => "DEFAULT", "request" => "x"})
        assert_reply(view, %{ok: false, error: "Only this team's members" <> _})

        # Saving a project flow syncs its labels to the project's teams.
        render_hook(view, "factory_save", %{"team" => "project:checkout", "version" => 0, "definition" => template})
        assert_reply(view, %{ok: true})
        assert_receive {:graphql, _, %{input: %{name: "factory"}}}, 1_000

        render_hook(view, "factory_reset", %{"team" => "project:checkout"})
        assert_reply(view, %{ok: true})
        refute Store.custom?("project:checkout")

        render_hook(view, "factory_reset", %{"team" => "WEB"})
        assert_reply(view, %{ok: false})
      after
        System.put_env("PATH", path)
        File.rm_rf!(bin)
      end
    end

    test "the team picker narrows the dashboard to one team's work and projects", %{ada: ada, mia: mia} do
      UsageLedger.observe_issue(%Issue{id: "1", identifier: "PAY-1", state: "Todo", project_slug: "checkout"})
      UsageLedger.observe_issue(%Issue{id: "2", identifier: "WEB-1", state: "Todo", project_slug: "site"})

      {:ok, view, html} = live(session_for(ada), "/")
      assert html =~ ~s(<option value="all" selected="">All teams</option>)
      assert html =~ ~s(<option value="WEB">)

      render_change(element(view, "#team-picker"), %{"team" => "PAY"})
      assert_patch(view, "/?team=PAY")
      json = view |> element("#factory-data") |> render() |> data_json()
      assert Enum.map(json["teams"], & &1["key"]) == ["PAY", "project:checkout"]

      render_change(element(view, "#team-picker"), %{"team" => "all"})
      assert_patch(view, "/")

      # Teams the viewer can't see fall back to all of their own.
      {:ok, member_view, html} = live(session_for(mia), "/?team=web")
      assert html =~ ~s(<option value="all" selected="">All teams</option>)
      refute html =~ ~s(<option value="WEB">)
      json = member_view |> element("#factory-data") |> render() |> data_json()
      assert Enum.map(json["teams"], & &1["key"]) == ["PAY", "project:checkout"]
    end

    test "the project picker narrows the dashboard to one project; the agent count stays Symphony-wide", ctx do
      UsageLedger.observe_issue(%Issue{id: "1", identifier: "PAY-1", state: "Todo", project_slug: "checkout"})
      UsageLedger.observe_issue(%Issue{id: "2", identifier: "WEB-1", state: "Todo", project_slug: "site"})
      UsageLedger.observe_issue(%Issue{id: "3", identifier: "PAY-2", state: "Todo", project_slug: "billing"})
      set_running(ctx.orchestrator, [running_agent("PAY-1", "checkout"), running_agent("WEB-1", "site"), running_agent("PAY-2", "billing")])

      {:ok, view, html} = live(session_for(ctx.ada), "/?team=PAY")
      assert html =~ ~r{3/\d+ agents}
      assert html =~ "PAY-1"
      refute html =~ "WEB-1"
      assert html =~ ~s(<option value="checkout">)
      refute html =~ ~s(<option value="site">)

      render_change(element(view, "#team-picker"), %{"team" => "PAY", "project" => "checkout"})
      assert_patch(view, "/?team=PAY&project=checkout")
      html = render(view)
      json = view |> element("#factory-data") |> render() |> data_json()
      assert Enum.map(json["teams"], & &1["key"]) == ["project:checkout"]
      assert json["scope"] == "project:checkout"
      assert html =~ ~r{3/\d+ agents}
      assert html =~ "PAY-1"
      refute html =~ "PAY-2"

      # Picking another team starts from all of its projects.
      render_change(element(view, "#team-picker"), %{"team" => "WEB", "project" => "checkout"})
      assert_patch(view, "/?team=WEB")

      # A project outside the chosen team falls back to all of the team's.
      {:ok, _view, html} = live(session_for(ctx.ada), "/?team=PAY&project=site")
      assert html =~ ~s(<option value="all" selected="">All projects</option>)
    end

    test "ended sessions are listed beside live ones, searchable, and only for the viewer's teams", ctx do
      set_running(ctx.orchestrator, [running_agent("PAY-1", "checkout")])
      SessionHistory.record(running_agent("PAY-7", "checkout", title: "Fix the login page"), :finished)
      SessionHistory.record(running_agent("WEB-9", "site", title: "Fix the login form"), :crashed, "agent exited: :boom")
      assert length(SessionHistory.list()) == 2

      {:ok, view, html} = live(session_for(ctx.mia), "/")
      # Live by default, with the ended ones counted.
      assert html =~ "PAY-1"
      refute html =~ "PAY-7"
      assert html =~ ~r{Completed\s*<span class="muted numeric">1</span>}

      html = render_click(view, "sessions_view", %{"view" => "completed"})
      assert html =~ "PAY-7"
      assert html =~ "Finished"
      assert html =~ "💬 Transcript"
      refute html =~ "WEB-9"
      refute html =~ "Watch the agent"

      html = render_click(view, "sessions_view", %{"view" => "all"})
      assert html =~ "PAY-1"
      assert html =~ "PAY-7"

      html = view |> element("#sessions-filter") |> render_change(%{"query" => "pay-7"})
      assert html =~ "PAY-7"
      refute html =~ "Work on PAY-1"

      html = view |> element("#sessions-filter") |> render_change(%{"query" => "nothing like it"})
      assert html =~ "No sessions match"

      # Filtering never waits on the orchestrator.
      snapshots = :sys.get_state(ctx.orchestrator)[:snapshots]
      render_click(view, "sessions_view", %{"view" => "live"})
      view |> element("#sessions-filter") |> render_change(%{"query" => "", "window" => "week"})
      assert :sys.get_state(ctx.orchestrator)[:snapshots] == snapshots

      {:ok, view, _html} = live(session_for(ctx.ada), "/")
      html = render_click(view, "sessions_view", %{"view" => "completed"})
      assert html =~ "WEB-9"
      assert html =~ "Crashed"
    end

    test "the health strip says whether the factory works and flags a quiet agent as stuck", ctx do
      quiet_since = DateTime.add(DateTime.utc_now(), -3_600, :second)
      set_running(ctx.orchestrator, [running_agent("PAY-1", "checkout", started_at: quiet_since, last_at: quiet_since)])

      {:ok, _view, html} = live(session_for(ctx.ada), "/")
      assert html =~ ~s(id="health")
      assert html =~ "Stuck"
      assert html =~ "No update for"
      assert html =~ "row-stuck"
      # Cost lives on the traces and metrics page now.
      refute html =~ ~s(id="spend")
      # Users is in the account menu, not the page links; Sessions is gone.
      refute html =~ ~s(class="topnav-link" href="/admin/users")
      refute html =~ ~s(href="/#sessions")
      assert html =~ ~s(<a href="/admin/users">Users</a>)

      UsageLedger.observe_issue(%Issue{id: "1", identifier: "PAY-1", state: "Todo", project_slug: "checkout"})
      {:ok, view, html} = live(session_for(ctx.ada), "/insights?team=PAY")
      assert html =~ ~s(id="team-picker")
      assert html =~ ~s(<option value="PAY" selected="")
      assert html =~ ~s(id="cost-by-stage")
      render_change(element(view, "#team-picker"), %{"team" => "all"})
      assert_patch(view, "/insights?range=day")
    end

    test "AI drafts run in the background and are pushed when ready", %{mia: mia} do
      bin = Path.join(System.tmp_dir!(), "symphony-editor-bin-#{System.unique_integer([:positive])}")
      File.mkdir_p!(bin)
      draft = Jason.encode!(%{"instructions" => "Do QA.", "transitions" => [], "skill" => nil})
      File.write!(Path.join(bin, "claude"), "#!/bin/sh\nprintf '%s' '#{draft}'\n")
      File.chmod!(Path.join(bin, "claude"), 0o755)
      path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> path)

      try do
        {:ok, view, _html} = live(session_for(mia), "/")
        render_hook(view, "factory_assist", %{"team" => "PAY", "stage" => "merge", "request" => "Use a merge queue.", "definition" => Store.get("PAY")})
        assert_reply(view, %{ok: true, pending: true, ref: ref})
        assert_push_event(view, "factory_assist_result", %{ref: ^ref, ok: true, suggestion: %{instructions: "Do QA."}}, 5_000)

        render_hook(view, "factory_assist", %{"team" => "PAY", "stage" => "merge", "request" => "", "definition" => %{"bad" => true}})
        assert_reply(view, %{ok: true, ref: ref2})
        assert_push_event(view, "factory_assist_result", %{ref: ^ref2, ok: false, error: "Describe what the stage should do."}, 5_000)

        render_hook(view, "factory_assist", %{"team" => "WEB", "stage" => "merge", "request" => "x"})
        assert_reply(view, %{ok: false, error: "Only this team's members" <> _})
      after
        System.put_env("PATH", path)
        File.rm_rf!(bin)
      end
    end
  end
end
