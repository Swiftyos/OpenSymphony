defmodule SymphonyElixir.ConfigCoverageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.IssueConfig

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-coverage-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root}
  end

  defp load_project_workflow(root, front_matter, prompt \\ "Project prompt.") do
    path = Path.join(root, "WORKFLOW-#{System.unique_integer([:positive])}.md")
    File.write!(path, "---\n" <> front_matter <> "---\n" <> prompt <> "\n")
    ProjectWorkflow.load(path)
  end

  defp invalid_message(root, front_matter) do
    assert {:error, {:invalid_project_workflow_config, message}} = load_project_workflow(root, front_matter)
    message
  end

  describe "ProjectWorkflow.load/1" do
    test "rejects unsupported nested keys and non-map sections", %{root: root} do
      assert invalid_message(root, "agent:\n  bogus: 1\n") ==
               ~s(unsupported key "agent.bogus" in project workflow)

      assert invalid_message(root, "claude: plain-string\n") == "claude must be a map in project workflow"
    end

    test "normalizes non-string keys before validating top-level keys", %{root: root} do
      assert invalid_message(root, "true: 1\n") == ~s(unsupported key "true" in project workflow)
      assert invalid_message(root, "7: 1\n") == ~s(unsupported key "7" in project workflow)
    end

    test "reports changeset errors for each section", %{root: root} do
      assert invalid_message(root, "hooks:\n  timeout_ms: 0\n") == "timeout_ms must be greater than 0"
      assert invalid_message(root, "agent:\n  max_turns: 0\n") == "max_turns must be greater than 0"
      assert invalid_message(root, "codex:\n  turn_timeout_ms: 0\n") == "turn_timeout_ms must be greater than 0"

      assert invalid_message(root, "opencode:\n  model: no-provider\n") ==
               "model must use provider/model format"

      assert invalid_message(root, "claude:\n  permission_mode: yolo\n") ==
               "permission_mode must be one of: acceptEdits, auto, bypassPermissions, default, dontAsk, plan"
    end

    test "accepts valid provider overrides and drops nil values", %{root: root} do
      front_matter = """
      tracker:
        active_states: [Todo, Review]
      agent:
        backend: null
        max_turns: 4
      opencode:
        model: openai/gpt-5
      claude:
        permission_mode: plan
      """

      assert {:ok, workflow} = load_project_workflow(root, front_matter)
      assert workflow.config["tracker"] == %{"active_states" => ["Todo", "Review"]}
      assert workflow.config["agent"] == %{"max_turns" => 4}
      assert workflow.agent.max_turns == 4
      assert workflow.opencode.model == "openai/gpt-5"
      assert workflow.claude.permission_mode == "plan"

      assert {:ok, blank_model} = load_project_workflow(root, "opencode:\n  model: \"  \"\n")
      assert blank_model.opencode.model == "  "
    end
  end

  describe "IssueConfig.resolve/2" do
    test "legacy mode falls back to the default prompt when the workflow prompt is blank" do
      write_workflow_file!(Workflow.workflow_file_path(), prompt: "   ")

      assert {:ok, %IssueConfig{mode: :legacy} = issue_config} = IssueConfig.resolve(%{identifier: "MT-1"})
      assert issue_config.prompt_template == Config.default_prompt_template()
      assert issue_config.workflow_path == Workflow.workflow_file_path()
    end

    test "global mode reports missing routes and routes without a workflow", %{root: root} do
      config_path = Path.join(root, "symphony.yml")

      File.write!(config_path, """
      tracker:
        kind: linear
        api_key: token
        project_slug: alpha
      workspace:
        root: #{Path.join(root, "workspaces")}
      """)

      SymphonyConfig.set_config_file_path(config_path)
      assert Config.startup_mode() == :global

      assert {:error, {:missing_project_workflow, "alpha"}} = IssueConfig.resolve(%{project_slug: "alpha"})

      assert {:error, {:missing_project_route, "beta"}} = IssueConfig.resolve(%{project_slug: "beta"})
      assert {:error, {:missing_project_route, "gamma"}} = IssueConfig.resolve(%{"project_slug" => "gamma"})
      assert {:error, {:missing_project_route, nil}} = IssueConfig.resolve(%{identifier: "MT-2"})
    end
  end
end
