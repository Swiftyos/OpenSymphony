defmodule SymphonyElixir.RunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunnerTestSupport, as: Support
  alias SymphonyElixir.{RunSpec, RunToken, SessionStore, Transcript}
  alias SymphonyElixir.Factory.{Definition, Store}

  setup do
    root = Support.temp_root!("runner")
    Support.setup_runs!(root)
    endpoint = Support.start_endpoint!()
    previous_state_root = Application.get_env(:symphony_elixir, :state_root)
    Application.put_env(:symphony_elixir, :state_root, Path.join(root, "state"))

    on_exit(fn ->
      case previous_state_root do
        nil -> Application.delete_env(:symphony_elixir, :state_root)
        value -> Application.put_env(:symphony_elixir, :state_root, value)
      end
    end)

    %{root: root, endpoint: endpoint}
  end

  test "Runner.run drives a run to the in-process controller and exits normal", %{root: root, endpoint: endpoint} do
    issue_id = "issue-runner-e2e"
    run_id = "run-runner-e2e"
    identifier = "MT-RUNNER-E2E"
    issue = Support.issue_fixture(issue_id, identifier)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_backend: "claude",
      workspace_root: Path.join(root, "workspaces"),
      hook_after_create: "printf '# test\\n' > README.md",
      claude_command: Support.write_fake_claude_launcher!(root),
      max_turns: 1
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    record = Support.record_run!(issue_id, run_id, identifier: identifier, backend: "claude", epoch: 1)

    # A real runner application starts the poller registry; in this already
    # started test application Runner has to start the missing one.
    ExUnit.Callbacks.stop_supervised(SymphonyElixir.RunnerCommandPoller.registry())

    spec = %RunSpec{
      run_id: run_id,
      epoch: record.epoch,
      attempt: 0,
      issue: issue,
      worker_host: nil,
      backend: "claude",
      effort: nil,
      account: nil,
      controller_url: endpoint.url,
      token: RunToken.sign(run_id, record.epoch)
    }

    assert {:ok, spec_path} = RunSpec.write(spec)
    watcher = Task.async(fn -> watch_session(issue_id, 5_000) end)

    assert :ok = SymphonyElixir.Runner.run(spec_path)

    assert %{"backend" => "claude", "session_id" => session_id} = Task.await(watcher, 6_000)
    assert is_binary(session_id)

    assert_receive {:orchestrator_message, {:worker_runtime_info, ^issue_id, %{workspace_path: workspace}}}, 5_000
    assert workspace =~ identifier

    assert_receive {:orchestrator_message, {:agent_worker_update, ^issue_id, %{event: :turn_started}}}, 5_000
    assert_receive {:orchestrator_message, {:agent_worker_update, ^issue_id, %{event: :turn_completed}}}, 5_000
    assert_receive {:orchestrator_message, {:run_finished, ^issue_id, ^run_id, "normal"}}, 5_000

    # The controller-side transcript saw the run's turn.
    assert [%{kind: "turn", turn: 1, backend: "claude"} | _rest] = Transcript.entries(identifier)

    # AgentRunner deletes the session when the run ends; the watcher saw it first.
    assert SessionStore.get(issue_id) == nil
    SymphonyElixir.RunnerCommands.reset()
  end

  test "a runner without the controller's flows picks its issue up with the flow from its spec", %{root: root, endpoint: endpoint} do
    issue_id = "issue-runner-flow"
    run_id = "run-runner-flow"
    identifier = "MT-RUNNER-FLOW"
    scope = "project:runner-flow"
    issue = %{Support.issue_fixture(issue_id, identifier, state: "Ready for pickup", labels: []) | project_slug: "runner-flow"}

    # The project's queue waits in "Ready for pickup", which the built-in template doesn't know.
    stages = Enum.map(Definition.default_template()["stages"], &if(&1["id"] == "todo", do: Map.put(&1, "linear_state", "Ready for pickup"), else: &1))
    definition = %{Definition.default_template() | "stages" => stages}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready for pickup", "In Progress"],
      agent_backend: "claude",
      workspace_root: Path.join(root, "workspaces"),
      hook_after_create: "printf '# test\\n' > README.md",
      claude_command: Support.write_fake_claude_launcher!(root),
      max_turns: 1
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    record = Support.record_run!(issue_id, run_id, identifier: identifier, backend: "claude", epoch: 1)
    ExUnit.Callbacks.stop_supervised(SymphonyElixir.RunnerCommandPoller.registry())
    on_exit(fn -> Store.reset_team(scope) end)

    refute Store.custom?(scope)

    spec = %RunSpec{
      run_id: run_id,
      epoch: record.epoch,
      attempt: 0,
      issue: issue,
      backend: "claude",
      controller_url: endpoint.url,
      token: RunToken.sign(run_id, record.epoch),
      flow: %{"scope" => scope, "definition" => definition}
    }

    assert {:ok, spec_path} = RunSpec.write(spec)
    assert :ok = SymphonyElixir.Runner.run(spec_path)

    assert_receive {:memory_tracker_stage_update, ^issue_id, "In Progress", "implement"}, 5_000
    assert Store.custom?(scope)
    SymphonyElixir.RunnerCommands.reset()
  end

  test "a failed run posts a non-normal finished event and returns an error", %{root: root, endpoint: endpoint} do
    issue_id = "issue-runner-fail"
    run_id = "run-runner-fail"
    identifier = "MT-RUNNER-FAIL"
    issue = Support.issue_fixture(issue_id, identifier)
    failing = Path.join(root, "failing-claude.sh")
    File.write!(failing, "#!/bin/sh\nexit 1\n")
    File.chmod!(failing, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_backend: "claude",
      workspace_root: Path.join(root, "workspaces"),
      claude_command: failing,
      accounts_enabled: true,
      accounts_store_root: Path.join(root, "accounts"),
      max_turns: 1
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    record = Support.record_run!(issue_id, run_id, identifier: identifier, backend: "claude", epoch: 1)
    {:ok, _account} = SymphonyElixir.Accounts.create_or_update("claude", "acct-valid", [], Config.settings!())

    spec = %RunSpec{
      run_id: run_id,
      epoch: record.epoch,
      attempt: 0,
      issue: issue,
      backend: "claude",
      account: %{backend: "claude", id: "acct-valid"},
      controller_url: endpoint.url,
      token: RunToken.sign(run_id, record.epoch)
    }

    assert {:ok, spec_path} = RunSpec.write(spec)

    assert {:error, reason} = SymphonyElixir.Runner.run(spec_path)
    assert is_binary(reason)

    assert_receive {:orchestrator_message, {:run_finished, ^issue_id, ^run_id, finished_reason}}, 5_000
    assert finished_reason != "normal"
    SymphonyElixir.RunnerCommands.reset()
  end

  test "the runner keeps retrying its finished event while the controller can't apply it", %{root: root, endpoint: endpoint} do
    {spec_path, run_id, issue_id} = unacked_runner_spec!(root, endpoint, "keep", [])
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.RunnerCommands)

    task = Task.async(fn -> SymphonyElixir.Runner.run(spec_path) end)

    try do
      # The finished event is written, but the controller answers 503.
      assert wait_for(fn -> SymphonyElixir.RunOutbox.finished_reason(RunSpec.dir(run_id)) == "normal" end, 10_000)
      assert Task.yield(task, 1_500) == nil
    after
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.RunnerCommands)
    end

    assert :ok = Task.await(task, 15_000)
    assert_receive {:orchestrator_message, {:run_finished, ^issue_id, ^run_id, "normal"}}, 1_000
    SymphonyElixir.RunnerCommands.reset()
  end

  test "the finished flush gives up after agent.runner_finish_flush_ms", %{root: root, endpoint: endpoint} do
    {spec_path, run_id, issue_id} = unacked_runner_spec!(root, endpoint, "cap", agent_runner_finish_flush_ms: 300)
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.RunnerCommands)

    try do
      assert :ok = SymphonyElixir.Runner.run(spec_path)
      assert SymphonyElixir.RunOutbox.finished_reason(RunSpec.dir(run_id)) == "normal"
      refute_received {:orchestrator_message, {:run_finished, ^issue_id, _run_id, _reason}}
    after
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.RunnerCommands)
    end
  end

  test "a missing spec is reported without starting anything" do
    assert {:error, :enoent} = SymphonyElixir.Runner.run(Path.join(System.tmp_dir!(), "missing-runner-spec.json"))
  end

  defp unacked_runner_spec!(root, endpoint, suffix, workflow_overrides) do
    issue_id = "issue-runner-#{suffix}"
    run_id = "run-runner-#{suffix}"
    identifier = "MT-RUNNER-#{String.upcase(suffix)}"
    issue = Support.issue_fixture(issue_id, identifier)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      [
        tracker_kind: "memory",
        agent_backend: "claude",
        workspace_root: Path.join(root, "workspaces"),
        hook_after_create: "printf '# test\\n' > README.md",
        claude_command: Support.write_fake_claude_launcher!(root),
        max_turns: 1
      ] ++ workflow_overrides
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    record = Support.record_run!(issue_id, run_id, identifier: identifier, backend: "claude", epoch: 1)

    spec = %RunSpec{
      run_id: run_id,
      epoch: record.epoch,
      attempt: 0,
      issue: issue,
      backend: "claude",
      controller_url: endpoint.url,
      token: RunToken.sign(run_id, record.epoch)
    }

    {:ok, spec_path} = RunSpec.write(spec)
    {spec_path, run_id, issue_id}
  end

  defp wait_for(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      cond do
        fun.() -> true
        System.monotonic_time(:millisecond) > deadline -> false
        true -> Process.sleep(20) && nil
      end
    end)
    |> Enum.find(&is_boolean/1)
  end

  defp watch_session(issue_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_watch_session(issue_id, deadline)
  end

  defp do_watch_session(issue_id, deadline) do
    case SessionStore.get(issue_id) do
      %{} = record ->
        record

      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          nil
        else
          Process.sleep(5)
          do_watch_session(issue_id, deadline)
        end
    end
  end
end
