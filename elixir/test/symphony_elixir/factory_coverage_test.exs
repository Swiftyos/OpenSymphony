defmodule SymphonyElixir.FactoryCoverageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentRoute, FactoryControls, IssueStage, UsageLedger}
  alias SymphonyElixir.Factory.{Definition, StagePrompt, Store}
  alias SymphonyElixir.Linear.{Adapter, GraphqlTool}
  alias SymphonyElixir.Tracker.Memory
  alias SymphonyElixirWeb.FactoryPresenter

  defmodule ScriptedLinearClient do
    def graphql(query, variables, opts \\ []) do
      send(self(), {:graphql_called, query, variables, opts})
      [result | rest] = Process.get(:scripted_linear_results)
      Process.put(:scripted_linear_results, rest)
      result
    end
  end

  setup do
    Store.reset()
    UsageLedger.reset()
    memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    linear_client = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      Store.reset()
      UsageLedger.reset()
      restore_app_env(:memory_tracker_issues, memory_issues)
      restore_app_env(:linear_client_module, linear_client)
    end)

    :ok
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp issue(identifier, state, labels \\ []) do
    %Issue{
      id: "id-" <> to_string(identifier),
      identifier: identifier,
      title: "Task",
      state: state,
      labels: labels,
      project_slug: "project",
      url: "https://linear.app/x/1"
    }
  end

  defp tmp_dir!(name) do
    dir = Path.join(System.tmp_dir!(), "symphony-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Inserts a definition straight into the store's table (owned by the Store
  # process), bypassing validation, to exercise renderers on raw shapes.
  defp insert_raw_definition!(team, definition) do
    :sys.replace_state(Store, fn state ->
      :ets.insert(:symphony_factories, {team, definition})
      state
    end)
  end

  describe "Factory.Definition" do
    test "exposes kinds and tolerates missing inputs" do
      template = Definition.default_template()

      assert Definition.kinds() == ["queue", "agent", "human", "parked", "done"]
      assert Definition.stage_for(template, nil, [], "factory") == nil
      assert Definition.stage(template, nil) == nil
      refute Definition.dispatchable?(nil)

      raw = %{"stages" => [%{"id" => "odd", "linear_state" => nil, "label" => nil}]}
      assert Definition.stage_for(raw, "Todo", [], "factory") == nil
    end

    test "validation reports non-object entries, duplicate defaults and repeated connections" do
      definition = %{
        "stages" => [
          %{"id" => "a", "name" => "A", "kind" => "agent", "linear_state" => "In Progress", "default" => true},
          %{"id" => "b", "name" => "B", "kind" => "done", "linear_state" => "In Progress", "label" => "b", "default" => true},
          %{"id" => 123, "name" => :numeric, "kind" => "queue", "linear_state" => "Todo"},
          "not a stage"
        ],
        "transitions" => [
          %{"from" => "a", "to" => "b"},
          %{"from" => "a", "to" => "b", "by" => "human"},
          "not a transition"
        ]
      }

      assert {:error, errors} = Definition.validate(definition)
      assert ~s(only one stage can be the default for "in progress") in errors
      assert "a → b is connected twice" in errors
      assert ~s(stage id "123" must be lowercase letters, digits, or dashes) in errors
      assert ~s(stage id "" must be lowercase letters, digits, or dashes) in errors
      assert ~s(stage "" can't connect to itself) in errors
      assert "connection  →  must be moved by agent or human" in errors
    end
  end

  describe "Factory.Store" do
    test "start_link/0 refuses a second store under the same name" do
      assert {:error, {:already_started, pid}} = Store.start_link()
      assert pid == Process.whereis(Store)
    end

    test "rejects unknown fields, invalid teams, and missing team keys" do
      assert Store.put_stage_field("PAY", "merge", "name", "x", "me") == {:error, {:unknown_field, "name"}}
      assert Store.reset_team("not a team!") == {:error, :invalid_team}
      assert Store.put(nil, Definition.default_template(), 0, "me") == {:error, :invalid_team}
    end
  end

  describe "Factory.Store with its own directory" do
    setup do
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Store)
      previous = Application.get_env(:symphony_elixir, :factories_dir)

      on_exit(fn ->
        restore_factories_dir(previous)
        Supervisor.restart_child(SymphonyElixir.Supervisor, Store)
      end)

      {:ok, previous_dir: previous}
    end

    defp restore_factories_dir(nil), do: Application.put_env(:symphony_elixir, :factories_dir, nil)
    defp restore_factories_dir(value), do: Application.put_env(:symphony_elixir, :factories_dir, value)

    test "skips unreadable or invalid definition files on load" do
      dir = tmp_dir!("factories-load")
      File.write!(Path.join(dir, "PAY.json"), "{not json")
      File.write!(Path.join(dir, "bad name.json"), Jason.encode!(Definition.default_template()))
      File.write!(Path.join(dir, "OPS.json"), Jason.encode!(Map.put(Definition.default_template(), "version", 4)))

      log = capture_log(fn -> start_supervised!({Store, dir: dir}) end)

      assert Store.teams() == ["OPS"]
      assert Store.get("OPS")["version"] == 4
      assert log =~ "Factory definition skipped path=#{Path.join(dir, "PAY.json")}"
      assert log =~ "Factory definition skipped path=#{Path.join(dir, "bad name.json")}"
    end

    test "project flows persist as project--<slug>.json and reload under their scope" do
      dir = tmp_dir!("factories-projects")
      File.write!(Path.join(dir, "project--web-app.json"), Jason.encode!(Definition.default_template()))
      File.write!(Path.join(dir, "project--bad slug.json"), Jason.encode!(Definition.default_template()))
      capture_log(fn -> start_supervised!({Store, dir: dir}) end)

      assert Store.projects() == ["web-app"]
      assert Store.teams() == []
      assert {:ok, %{"team" => "project:Checkout"}} = Store.put("project:Checkout", Definition.default_template(), 0, "me")
      assert File.exists?(Path.join(dir, "project--Checkout.json"))

      assert Store.reset_team("project:Checkout") == :ok
      refute File.exists?(Path.join(dir, "project--Checkout.json"))
      assert Store.reset_team("project:bad slug") == {:error, :invalid_team}
    end

    test "logs but keeps the save when persisting fails" do
      blocker = Path.join(tmp_dir!("factories-blocked"), "not-a-dir")
      File.write!(blocker, "file in the way")
      start_supervised!({Store, dir: blocker})

      log =
        capture_log(fn ->
          assert {:ok, %{"version" => 1, "team" => "PAY"}} = Store.put("PAY", Definition.default_template(), 0, "me")
        end)

      assert log =~ "Factory save failed team=PAY"
      assert Store.custom?("PAY")
    end

    test "defaults to ~/.symphony/factories when no directory is configured" do
      Application.put_env(:symphony_elixir, :factories_dir, :default)
      capture_log(fn -> start_supervised!(Store) end)

      assert is_list(Store.teams())
      assert %{dir: dir} = :sys.get_state(Store)
      assert dir == Path.expand("~/.symphony/factories")
    end
  end

  describe "Factory.StagePrompt" do
    test "renders nothing for issues without a stage" do
      assert StagePrompt.render(nil) == ""
      assert StagePrompt.render(issue("PAY-1", "Backlog")) == ""

      assert StagePrompt.variables(nil) ==
               %{"id" => nil, "name" => nil, "kind" => nil, "instructions" => nil, "prompt" => ""}
    end

    test "a final stage has no moves" do
      prompt = StagePrompt.render(issue("PAY-1", "Done"))
      assert prompt =~ "## Your current stage: Done"
      assert prompt =~ "Follow the workflow for this stage."
      assert prompt =~ "- None. This stage ends the flow."
    end

    test "missing instructions and criteria fall back to defaults" do
      insert_raw_definition!("RAW", %{
        "stages" => [
          %{"id" => "work", "name" => "Work", "kind" => "agent", "linear_state" => "Todo", "label" => nil},
          %{"id" => "done", "name" => "Done", "kind" => "done", "linear_state" => "Done", "label" => nil}
        ],
        "transitions" => [%{"from" => "work", "to" => "done", "by" => "agent"}]
      })

      prompt = StagePrompt.render(issue("RAW-1", "Todo"))
      assert prompt =~ "Follow the workflow for this stage."
      assert prompt =~ "- `done` → **Done**: when the work for this stage is done."
    end
  end

  describe "FactoryControls" do
    test "unknown stages and keys fall back to no overrides" do
      none = %{paused: false, max_agents: nil, backend: nil, effort: nil}

      assert FactoryControls.get({"PAY", "nope"}) == none
      assert FactoryControls.get(nil) == none
      assert FactoryControls.put("implement", "colour", "red") == {:error, {:invalid_control, "colour", "red"}}
    end
  end

  describe "IssueStage" do
    test "team keys need a non-empty prefix" do
      assert IssueStage.team(issue("PAY12", "Todo")) == nil
      assert IssueStage.team(issue("-12", "Todo")) == nil
      assert IssueStage.team(issue("PAY-12", "Todo")) == "PAY"
    end

    test "non-issues and unknown states are never paused or active" do
      refute IssueStage.paused?(nil)
      refute IssueStage.dispatch_paused?(nil)
      refute IssueStage.active?(nil)
      refute IssueStage.active?(issue("PAY-1", nil))
      refute IssueStage.active_state?(nil)
      assert IssueStage.warnings(nil) == []

      refute IssueStage.paused?(issue("PAY-1", "Backlog"))
      assert IssueStage.paused?(issue("PAY-1", "Backlog", ["factory/blocked"]))
    end

    test "warnings only fire for multiple stage labels" do
      assert IssueStage.warnings(issue("PAY-1", "In Progress", ["factory/merge"])) == []
      # A stage label that matches no labelled stage in this state is ignored.
      assert IssueStage.warnings(issue("PAY-1", "Todo", ["factory/merge", "factory/rework"])) == []
      assert IssueStage.stage(issue("PAY-1", "Todo", ["factory/merge"])) == "todo"

      assert [warning] = IssueStage.warnings(issue("PAY-1", "In Progress", ["factory/merge", "factory/rework"]))
      assert warning =~ "multiple stage labels"
    end

    test "active_state_names/0 merges configured and factory states" do
      assert IssueStage.active_state_names() == ["Todo", "In Progress"]
    end

    test "paused stages may be configured as non-strings" do
      settings = Config.settings!()
      settings = %{settings | tracker: %{settings.tracker | paused_stages: [:merge]}}

      assert IssueStage.paused?(issue("PAY-1", "In Progress", ["factory/merge"]), settings)
      refute IssueStage.paused?(issue("PAY-1", "In Progress", ["factory/rework"]), settings)
    end
  end

  describe "AgentRoute" do
    test "label helpers and effort mappings" do
      assert Enum.sort(AgentRoute.backend_labels()) == ["claude", "codex", "opencode"]
      assert "thinking/high" in AgentRoute.effort_labels()
      refute "effort/high" in AgentRoute.effort_labels()
      assert AgentRoute.effort_values() == ["low", "medium", "high", "xhigh", "max"]
      refute AgentRoute.local_only_backend?("codex")
      assert AgentRoute.local_only_backend?("opencode")
      assert AgentRoute.codex_effort("medium") == "medium"
      assert AgentRoute.codex_effort("extreme") == nil
      assert AgentRoute.codex_effort(nil) == nil
    end

    test "conflicting thinking labels without a default effort are ignored" do
      route = AgentRoute.resolve(issue("PAY-1", "Todo", ["thinking/low", "effort/high", "   ", nil, 7]))

      assert route.effort == nil
      assert route.warnings == ["multiple thinking labels (low, high) found; ignoring effort override"]
    end
  end

  describe "Tracker.Memory" do
    test "set_stage leaves other issues untouched" do
      other = issue("PAY-2", "Todo", ["factory/implement"])

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        issue("PAY-1", "Todo", ["factory/implement"]),
        other
      ])

      assert :ok = Memory.set_stage("id-PAY-1", "In Progress", nil)

      assert [%Issue{state: "In Progress", labels: []}, ^other] =
               Application.get_env(:symphony_elixir, :memory_tracker_issues)
    end
  end

  describe "Linear.Adapter.set_stage" do
    setup do
      Application.put_env(:symphony_elixir, :linear_client_module, ScriptedLinearClient)
      :ok
    end

    defp lookup(state_nodes) do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{"id" => "team-1", "states" => %{"nodes" => state_nodes}},
             "labels" => %{
               "nodes" => [
                 %{"id" => "label-claude", "name" => "claude"},
                 %{"id" => "label-old", "name" => "implement", "parent" => %{"name" => "factory"}}
               ]
             }
           },
           "issueLabels" => %{"nodes" => []}
         }
       }}
    end

    defp script(results), do: Process.put(:scripted_linear_results, results)

    test "clearing the stage keeps only non-stage labels" do
      script([lookup([%{"id" => "state-done"}]), {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}])

      assert :ok = Adapter.set_stage("issue-1", "Done", nil, api_key: "k")
      assert_received {:graphql_called, _lookup, %{stage: "", flat: "factory/"}, [api_key: "k"]}
      assert_received {:graphql_called, _mutation, %{stateId: "state-done", labelIds: ["label-claude"]}, _opts}
    end

    test "reports a missing state, a failed update, and unexpected responses" do
      script([lookup([])])
      assert Adapter.set_stage("issue-1", "Nowhere", nil) == {:error, :state_not_found}

      script([lookup([%{"id" => "state-1"}]), {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}])
      assert Adapter.set_stage("issue-1", "Done", nil) == {:error, :issue_update_failed}

      script([lookup([%{"id" => "state-1"}]), :unexpected])
      assert Adapter.set_stage("issue-1", "Done", nil) == {:error, :issue_update_failed}
    end
  end

  describe "Linear.GraphqlTool" do
    test "execute/1 rejects invalid arguments before calling Linear" do
      response = GraphqlTool.execute(%{"query" => "   "})
      assert response["success"] == false
      assert inspect(response) =~ "query"
    end
  end

  describe "PromptBuilder in global mode" do
    defp init_repo!(path) do
      File.mkdir_p!(path)
      File.write!(Path.join(path, "README.md"), "prompt builder\n")

      for args <- [
            ["init", "-b", "main"],
            ["config", "user.name", "Test User"],
            ["config", "user.email", "test@example.com"],
            ["add", "README.md"],
            ["commit", "-m", "initial"]
          ] do
        {_, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
      end
    end

    test "uses the project workflow prompt and raises when no route matches" do
      root = tmp_dir!("prompt-builder-global")
      repo = Path.join(root, "repo")
      init_repo!(repo)
      write_project_workflow_file!(Path.join(repo, "PROJECT_WORKFLOW.md"), prompt: "Project prompt for {{ issue.identifier }}")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "PROJECT_WORKFLOW.md"], stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-m", "workflow"], stderr_to_stdout: true)

      config_path = Path.join(root, "symphony.yml")

      write_symphony_config_file!(config_path,
        workspace_root: Path.join(root, "workspaces"),
        projects: [%{linear_project: "project", repo: repo, workflow: "./PROJECT_WORKFLOW.md"}]
      )

      SymphonyConfig.set_config_file_path(config_path)

      prompt = PromptBuilder.build_prompt(issue("PAY-1", "Backlog"))
      assert prompt == "Project prompt for PAY-1"

      assert_raise RuntimeError, ~r/workflow_unavailable: \{:missing_project_route, "elsewhere"\}/, fn ->
        PromptBuilder.build_prompt(%{issue("PAY-2", "Backlog") | project_slug: "elsewhere"})
      end
    end
  end

  describe "FactoryPresenter" do
    test "unpriced rows, missing rates, and only in-diagram unexpected edges are reported" do
      UsageLedger.observe_issue(issue("PAY-1", "Backlog"))
      UsageLedger.observe_issue(issue("PAY-1", "Todo"))
      UsageLedger.observe_issue(issue("PAY-1", "Done"))

      UsageLedger.record_tokens(%{issue: issue("PAY-1", "Done"), backend: "claude"}, %{input_tokens: 2_000_000, output_tokens: 10})
      UsageLedger.record_tokens(%{issue: issue("PAY-2", "Todo"), backend: "codex"}, %{input_tokens: 5, output_tokens: 5})

      settings = %{Config.settings!() | pricing: %{"claude" => %{"input_per_mtok" => 2, "output_per_mtok" => "n/a"}}}
      payload = FactoryPresenter.payload([], settings)

      costs = Map.new(payload.usage, &{&1.backend, &1.cost_usd})
      assert costs == %{"claude" => 4.0, "codex" => nil}

      # Usage priced when it was spent keeps that price.
      spent = %{input_tokens: 1, output_tokens: 1, cost_micros: 2_500_000}
      UsageLedger.record_tokens(%{issue: issue("PAY-3", "Todo"), backend: "opencode"}, spent)
      assert Enum.find(FactoryPresenter.payload([], settings).usage, &(&1.backend == "opencode")).cost_usd == 2.5

      # Transitions are reported per team, keyed "from>to", even ones the flow doesn't define.
      assert payload.flows["PAY"].edges == %{"todo>done" => 1}
      assert payload.flows["PAY"].nodes["done"].count == 1
    end
  end
end
