defmodule SymphonyElixir.DelayedRestartTest do
  use SymphonyElixir.TestSupport

  # config/test.exs points the restart at `send(:delayed_restart_test_probe, :stopped)`
  # instead of stopping the VM.

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-delayed-restart-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done"],
      poll_interval_ms: 30_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Process.register(self(), :delayed_restart_test_probe)
    name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      restore_memory_tracker_issues(previous)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(test_root)
    end)

    %{pid: pid, name: name}
  end

  defp restore_memory_tracker_issues(nil), do: Application.delete_env(:symphony_elixir, :memory_tracker_issues)
  defp restore_memory_tracker_issues(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  # The issue also exists in the memory tracker, so reconciling keeps the run.
  defp fake_running(pid, issue_id) do
    issue = %Issue{id: issue_id, identifier: "MT-1", title: "Running", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    agent = spawn(fn -> receive do: (:stop -> :ok) end)
    ref = Process.monitor(agent)

    entry = %{
      pid: agent,
      ref: ref,
      identifier: "MT-1",
      issue: issue,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn state -> %{state | running: %{issue_id => entry}, claimed: MapSet.new([issue_id])} end)
    {agent, ref}
  end

  test "with nothing running, the restart happens straight away", %{name: name} do
    assert %{pending: true, requested_by: "test", waiting_for: 0} = Orchestrator.request_delayed_restart("test", name)
    assert_receive :stopped, 1_000
  end

  test "it waits for running agents, then restarts when the last one finishes", %{pid: pid, name: name} do
    {agent, ref} = fake_running(pid, "issue-1")

    assert %{pending: true, waiting_for: 1} = Orchestrator.request_delayed_restart("test", name)
    refute_receive :stopped, 200

    # The agent's task finishing reaches the orchestrator as its monitor's :DOWN.
    send(agent, :stop)
    send(pid, {:DOWN, ref, :process, agent, :normal})
    assert_receive :stopped, 1_000
  end

  test "no new runs start while a restart is pending, and asking twice keeps the first request",
       %{pid: pid, name: name} do
    {_agent, _ref} = fake_running(pid, "issue-1")
    first = Orchestrator.request_delayed_restart("ada", name)
    assert Orchestrator.request_delayed_restart("mia", name).requested_at == first.requested_at

    assert %{requested_by: "ada"} = :sys.get_state(pid).delayed_restart
    refute_receive :stopped, 200
  end

  test "the snapshot shows a pending restart to the dashboard and API", %{pid: pid, name: name} do
    pending = %{requested_at: DateTime.utc_now(), requested_by: "ada"}
    :sys.replace_state(pid, fn state -> %{state | delayed_restart: pending} end)
    assert %{delayed_restart: %{pending: true, requested_by: "ada", waiting_for: 0}} = Orchestrator.snapshot(name, 1_000)
  end

  test "a restart still happens when the last run is stopped by reconciling, not by a :DOWN",
       %{pid: pid, name: name} do
    {_agent, _ref} = fake_running(pid, "issue-1")
    Orchestrator.request_delayed_restart("test", name)
    refute_receive :stopped, 200

    # The issue disappears from the tracker; the next poll stops its run.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    send(pid, :tick)
    assert_receive :stopped, 2_000
  end

  test "cancelling lets runs start again and never restarts", %{pid: pid, name: name} do
    {agent, ref} = fake_running(pid, "issue-1")
    Orchestrator.request_delayed_restart("test", name)

    assert %{pending: false} = Orchestrator.cancel_delayed_restart(name)
    send(agent, :stop)
    send(pid, {:DOWN, ref, :process, agent, :normal})
    refute_receive :stopped, 300
    assert :sys.get_state(pid).delayed_restart == nil
  end
end
