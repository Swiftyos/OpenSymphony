defmodule SymphonyElixir.FactoryDefinitionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Factory.{Definition, Store}

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
    :ok
  end

  defp stage_ids(definition), do: Enum.map(definition["stages"], & &1["id"])

  test "the default template is valid and maps today's flow" do
    assert {:ok, template} = Definition.validate(Definition.default_template())
    assert stage_ids(template) == ["todo", "implement", "review", "rework", "merge", "blocked", "done"]
    assert Definition.active_states(template) == ["Todo", "In Progress"]
  end

  test "stages are found by Linear state and stage label, with a per-state default" do
    template = Definition.default_template()
    find = fn state, labels -> (Definition.stage_for(template, state, labels, "factory") || %{})["id"] end

    assert find.("Todo", []) == "todo"
    assert find.("In Progress", []) == "implement"
    assert find.("in progress", ["Factory/Merge", "claude"]) == "merge"
    assert find.("In Progress", ["factory/blocked"]) == "blocked"
    # A stage label from another state doesn't apply.
    assert find.("In Review", ["factory/merge"]) == "review"
    assert find.("Backlog", []) == nil
  end

  test "only queue and agent stages that aren't paused are dispatchable" do
    template = Definition.default_template()
    dispatchable = template["stages"] |> Enum.filter(&Definition.dispatchable?/1) |> Enum.map(& &1["id"])
    assert dispatchable == ["todo", "implement", "rework", "merge"]

    refute Definition.dispatchable?(%{Definition.stage(template, "merge") | "paused" => true})
  end

  test "validation reports every problem in plain language" do
    broken = %{
      "stages" => [
        %{"id" => "build", "name" => "Build", "kind" => "agent", "linear_state" => "In Progress", "label" => "build"},
        %{"id" => "build", "name" => "Again", "kind" => "robot", "linear_state" => "In Progress", "label" => "build"},
        %{"id" => "Bad Id", "name" => "", "kind" => "agent", "linear_state" => "", "max_agents" => 0}
      ],
      "transitions" => [%{"from" => "build", "to" => "ship", "by" => "agent"}, %{"from" => "build", "to" => "build", "by" => "bot"}]
    }

    assert {:error, errors} = Definition.validate(broken)
    assert "two stages share the id \"build\"" in errors
    assert "stage Again has unknown kind \"robot\"" in errors
    assert ~s(two stages use Linear state "in progress" with label "build") in errors
    assert Enum.any?(errors, &(&1 =~ "must be lowercase letters"))
    assert Enum.any?(errors, &(&1 =~ "max agents"))
    assert "a connection ends at unknown stage \"ship\"" in errors
    assert "stage \"build\" can't connect to itself" in errors
    assert "a factory needs a done stage" in errors

    assert {:error, ["definition must be an object"]} = Definition.validate("nope")
    assert {:error, errors} = Definition.validate(%{})
    assert "a factory needs at least one stage" in errors
  end

  test "teams start from the template and save their own versions" do
    assert Store.get("pay")["team"] == "PAY"
    refute Store.custom?("PAY")

    qa = %{
      "id" => "qa",
      "name" => "QA",
      "kind" => "agent",
      "linear_state" => "In Progress",
      "label" => "qa",
      "instructions" => "Run the e2e suite against the preview deploy."
    }

    edited =
      Store.get("PAY")
      |> Map.update!("stages", &(&1 ++ [qa]))
      |> Map.update!("transitions", &(&1 ++ [%{"from" => "implement", "to" => "qa", "by" => "agent", "criteria" => "PR open"}]))

    assert {:ok, saved} = Store.put("PAY", edited, 0, "mia")
    assert saved["version"] == 1
    assert saved["updated_by"] == "mia"
    assert "qa" in stage_ids(Store.get("PAY"))
    assert Store.custom?("pay")
    assert Store.teams() == ["PAY"]

    # Other teams still use the template.
    refute "qa" in stage_ids(Store.get("WEB"))

    # Saving against an old version is refused with the current definition.
    assert {:error, {:conflict, %{"version" => 1}}} = Store.put("PAY", edited, 0, "ada")

    assert {:ok, %{"version" => 2} = paused} = Store.put_stage_field("PAY", "qa", "paused", true, "ada")
    assert Definition.stage(paused, "qa")["paused"]
    assert {:error, _} = Store.put_stage_field("PAY", "qa", "max_agents", 0, "ada")
    assert {:error, {:unknown_stage, "nope"}} = Store.put_stage_field("PAY", "nope", "paused", true, "ada")
    assert {:error, :invalid_team} = Store.put("../etc", edited, 0, "eve")

    assert :ok = Store.reset_team("PAY")
    refute Store.custom?("PAY")
  end

  test "definitions persist to one JSON file per team and reload" do
    dir = Path.join(System.tmp_dir!(), "symphony-factories-#{System.unique_integer([:positive])}")
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Store)

    try do
      pid = start_supervised!({Store, dir: dir})
      definition = Map.put(Store.get("OPS"), "transitions", [])
      assert {:ok, _} = Store.put("OPS", definition, 0, "mia")
      assert File.exists?(Path.join(dir, "OPS.json"))

      # A fresh store (e.g. after a restart) loads it back.
      :ok = stop_supervised(Store)
      refute Process.alive?(pid)
      start_supervised!({Store, dir: dir})
      assert Store.custom?("OPS")
      assert Store.get("OPS")["transitions"] == []
      assert Store.get("OPS")["version"] == 1
    after
      stop_supervised(Store)
      {:ok, _} = Supervisor.restart_child(SymphonyElixir.Supervisor, Store)
      File.rm_rf!(dir)
    end
  end

  describe "agent prompts" do
    alias SymphonyElixir.{IssueStage, PromptBuilder}

    defp issue(identifier, state, labels),
      do: %Issue{id: "id-" <> identifier, identifier: identifier, title: "T", state: state, labels: labels, url: "https://linear.app/x"}

    test "the prompt carries the current stage's instructions and allowed moves" do
      write_workflow_file!(Workflow.workflow_file_path(), prompt: "Work on {{ issue.identifier }}.")
      prompt = PromptBuilder.build_prompt(issue("PAY-1", "In Progress", ["factory/merge"]))

      assert prompt =~ "Work on PAY-1."
      assert prompt =~ "## Your current stage: Merge"
      assert prompt =~ "Run the land skill"
      assert prompt =~ "- **Done** (you): The PR is merged. Set state `Done` and remove any `factory/*` label."
      assert prompt =~ "- **Blocked** (you): Landing is blocked. Set state `In Progress` and label `factory/blocked`"
    end

    test "a team's custom stage shapes its agents' prompts and only that team's" do
      write_workflow_file!(Workflow.workflow_file_path(), prompt: "Go.")

      qa = %{"id" => "qa", "name" => "QA", "kind" => "agent", "linear_state" => "In Progress", "label" => "qa", "instructions" => "Run the e2e suite."}

      edited =
        Store.get("PAY")
        |> Map.update!("stages", &(&1 ++ [qa]))
        |> Map.update!("transitions", fn ts ->
          ts ++
            [
              %{"from" => "implement", "to" => "qa", "by" => "agent", "criteria" => "PR is open"},
              %{"from" => "qa", "to" => "review", "by" => "agent", "criteria" => "E2E suite is green"}
            ]
        end)

      {:ok, _} = Store.put("PAY", edited, 0, "mia")

      assert IssueStage.stage(issue("PAY-2", "In Progress", ["factory/qa"])) == "qa"
      prompt = PromptBuilder.build_prompt(issue("PAY-2", "In Progress", ["factory/qa"]))
      assert prompt =~ "## Your current stage: QA"
      assert prompt =~ "Run the e2e suite."
      assert prompt =~ "- **In Review** (you): E2E suite is green."

      # Implement now offers the QA move for PAY, but not for WEB.
      assert PromptBuilder.build_prompt(issue("PAY-3", "In Progress", [])) =~ "**QA** (you)"
      refute PromptBuilder.build_prompt(issue("WEB-3", "In Progress", [])) =~ "**QA**"

      # WEB has no `qa` stage, so the label doesn't match a stage there.
      assert IssueStage.stage(issue("WEB-4", "In Progress", ["factory/qa"])) == "implement"
    end

    test "templates can place the stage section themselves" do
      write_workflow_file!(Workflow.workflow_file_path(), prompt: "{{ stage.prompt }}\n\nRest of the workflow.")
      prompt = PromptBuilder.build_prompt(issue("PAY-5", "Todo", []))
      assert prompt =~ "## Your current stage: Todo"
      assert length(String.split(prompt, "## Your current stage")) == 2
    end

    test "human and parked stages are never dispatched, even with stage labels" do
      write_workflow_file!(Workflow.workflow_file_path())
      assert IssueStage.paused?(issue("PAY-6", "In Progress", ["factory/blocked"]))
      assert IssueStage.paused?(issue("PAY-6", "In Progress", ["factory/merge", "factory/blocked"]))
      refute IssueStage.paused?(issue("PAY-6", "In Progress", ["factory/merge"]))
    end
  end
end
