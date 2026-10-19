defmodule SymphonyElixir.IssueStageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{IssueStage, PromptBuilder, Sandbox}

  defp issue(state, labels) do
    %Issue{id: "stage-#{System.unique_integer([:positive])}", identifier: "MT-900", title: "Stage", state: state, labels: labels}
  end

  defp empty_state do
    %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end

  test "stage comes from the factory label group and defaults to implement in progress" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert IssueStage.stage(issue("Todo", [])) == nil
    assert IssueStage.stage(issue("In Progress", [])) == "implement"
    assert IssueStage.stage(issue("In Progress", ["factory/merge"])) == "merge"
    assert IssueStage.stage(issue("In Progress", ["Factory/Rework", "claude"])) == "rework"
    assert IssueStage.stage(issue("Done", [])) == nil
  end

  test "paused stages block dispatch while other stages stay active" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert IssueStage.active?(issue("In Progress", ["factory/merge"]))
    refute IssueStage.active?(issue("In Progress", ["factory/blocked"]))
    refute IssueStage.active?(issue("In Progress", ["factory/review"]))
    refute IssueStage.active?(issue("In Review", ["factory/merge"]))

    assert Orchestrator.should_dispatch_issue_for_test(issue("In Progress", ["factory/merge"]), empty_state())
    refute Orchestrator.should_dispatch_issue_for_test(issue("In Progress", ["factory/blocked"]), empty_state())
  end

  test "conflicting stage labels prefer a paused stage and warn" do
    write_workflow_file!(Workflow.workflow_file_path())

    conflicted = issue("In Progress", ["factory/merge", "factory/blocked"])

    assert IssueStage.stage(conflicted) == "blocked"
    assert [warning] = IssueStage.warnings(conflicted)
    assert warning =~ "multiple stage labels"
  end

  test "running agent is stopped without workspace cleanup when its issue is paused" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-paused-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "MT-901")

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %{
        empty_state()
        | running: %{
            "issue-paused" => %{
              pid: agent_pid,
              ref: nil,
              identifier: "MT-901",
              issue: %Issue{id: "issue-paused", state: "In Progress", identifier: "MT-901"},
              started_at: DateTime.utc_now()
            }
          },
          claimed: MapSet.new(["issue-paused"])
      }

      paused = %Issue{id: "issue-paused", identifier: "MT-901", title: "Paused", state: "In Progress", labels: ["factory/blocked"]}
      updated = Orchestrator.reconcile_issue_states_for_test([paused], state)

      refute Map.has_key?(updated.running, "issue-paused")
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "prompt templates can read the stage and label prefix" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "stage={{ issue.stage }} prefix={{ factory.label_prefix }}")

    assert PromptBuilder.build_prompt(issue("In Progress", ["factory/merge"])) == "stage=merge prefix=factory"
  end

  test "shipped WORKFLOW.md renders for every stage" do
    workflow_path = Path.expand("../../WORKFLOW.md", __DIR__)
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_path |> File.read!() |> String.split("---\n", parts: 3) |> List.last())

    for labels <- [[], ["factory/rework"], ["factory/merge"]] do
      prompt = PromptBuilder.build_prompt(%{issue("In Progress", labels) | url: "https://linear.app/x", description: "d"})
      assert prompt =~ "## Symphony Workpad"
      refute prompt =~ "Codex Workpad"
    end
  end

  test "sandbox is a passthrough when disabled" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert {:ok, %{args: ["-lc", "echo hi"], cd: "/tmp/ws"}} = Sandbox.command_spec("/tmp/ws", "echo hi", ["SECRET"])
    assert :ok = Sandbox.validate_run("opencode", nil)
  end

  test "sandbox wraps commands in docker exec and passes env by name only" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-sandbox-#{System.unique_integer([:positive])}")

    try do
      write_workflow_file!(Workflow.workflow_file_path())
      File.mkdir_p!(test_root)
      fake_docker = Path.join(test_root, "fake-docker")
      File.write!(fake_docker, "#!/bin/sh\nif [ \"$1\" = inspect ]; then echo true; fi\nexit 0\n")
      File.chmod!(fake_docker, 0o755)

      settings = Config.settings!()
      settings = %{settings | sandbox: %{settings.sandbox | kind: "docker", command: fake_docker, image: "img"}}
      workspace = Path.join(test_root, "MT-902")

      assert {:ok, spec} = Sandbox.command_spec(workspace, "codex app-server", ["CODEX_HOME"], settings: settings)
      assert spec.executable == fake_docker
      assert spec.cd == nil

      assert spec.args ==
               ["exec", "--interactive", "--workdir", workspace, "--env", "CODEX_HOME", Sandbox.container_name(workspace), "bash", "-lc", "codex app-server"]

      assert {:error, {:sandbox_unsupported, :backend, "opencode"}} = Sandbox.validate_run("opencode", nil, settings)
      assert {:error, {:sandbox_unsupported, :ssh_worker_host, "host-a"}} = Sandbox.validate_run("codex", "host-a", settings)
    after
      File.rm_rf(test_root)
    end
  end

  test "container names are stable per workspace and docker-safe" do
    name = Sandbox.container_name("/tmp/ws root/MT 1")
    assert name == Sandbox.container_name("/tmp/ws root/MT 1")
    assert name =~ ~r/^symphony-MT_1-[0-9a-f]{10}$/
    refute name == Sandbox.container_name("/tmp/other/MT 1")
  end
end
