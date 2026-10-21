defmodule SymphonyElixir.DurableRunsProcessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunEvents
  alias SymphonyElixir.RunLauncher
  alias SymphonyElixir.RunLauncher.Process, as: ProcessLauncher
  alias SymphonyElixir.RunnerTestSupport, as: Support
  alias SymphonyElixir.RunRegistry
  alias SymphonyElixir.RunSpec
  alias SymphonyElixir.RunToken
  alias SymphonyElixir.RunWatcher

  defmodule FakeLauncher do
    @table :symphony_durable_fake_launcher

    def setup do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set])
      end

      :ets.delete_all_objects(@table)
      :ok
    end

    def set(ref, alive?), do: :ets.insert(@table, {ref, alive?})
    def stopped(ref), do: :ets.member(@table, {:stopped, ref})

    # What the next start_process/2 returns, and who hears about it.
    def on_start(result, recipient), do: :ets.insert(@table, {:on_start, result, recipient})

    # Makes this a process launcher (RunLauncher.start hands it the spec).
    def start_process(spec, _opts) do
      [{:on_start, result, recipient}] = :ets.lookup(@table, :on_start)
      registered = RunRegistry.load()[spec.issue.id]
      send(recipient, {:fake_start, spec, registered && registered.ref})

      case result do
        :ok ->
          ref = "fake:" <> spec.run_id
          set(ref, true)

          pid =
            spawn(fn ->
              receive do
                :stop -> :ok
              end
            end)

          {:ok, pid, ref}

        {:error, _reason} = error ->
          error
      end
    end

    def alive?(ref) do
      case :ets.lookup(@table, ref) do
        [{^ref, alive?}] -> alive?
        [] -> false
      end
    rescue
      ArgumentError -> false
    end

    def stop(ref) do
      if :ets.whereis(@table) != :undefined do
        :ets.insert(@table, {{:stopped, ref}, true})
        :ets.insert(@table, {ref, false})
      end

      :ok
    end
  end

  setup do
    root = Support.temp_root!("durable-process")
    Support.setup_runs!(root)
    FakeLauncher.setup()
    previous_state_root = Application.get_env(:symphony_elixir, :state_root)
    previous_launcher = Application.get_env(:symphony_elixir, :run_launcher)
    Application.put_env(:symphony_elixir, :state_root, Path.join(root, "state"))

    on_exit(fn ->
      restore_app_env(:state_root, previous_state_root)
      restore_app_env(:run_launcher, previous_launcher)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_backend: "claude",
      workspace_root: Path.join(root, "workspaces")
    )

    %{root: root}
  end

  test "a live registered run is adopted and finishes once without a retry during adoption", %{root: root} do
    issue = Support.issue_fixture("issue-adopt", "MT-ADOPT")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    run_id = "run-adopt"
    ref = "fake:adopt"
    FakeLauncher.set(ref, true)

    run_registry_entry(issue, run_id, %{
      attempt: 2,
      epoch: 4,
      launcher: FakeLauncher,
      ref: ref,
      started_at_unix_ms: System.system_time(:millisecond) - 1_000,
      metadata: %{
        identifier: issue.identifier,
        issue_title: issue.title,
        labels: issue.labels,
        backend: "claude",
        effort: "high",
        worker_host: nil,
        workspace_path: Path.join(root, "workspaces/MT-ADOPT"),
        issue: issue
      },
      last_seq: 7
    })

    name = Module.concat(__MODULE__, "AdoptOrchestrator")
    {:ok, pid} = Orchestrator.start_link(name: name)

    state = :sys.get_state(pid)
    assert %{run_id: ^run_id, epoch: 4, retry_attempt: 2, launcher: FakeLauncher, run_ref: ^ref} = state.running[issue.id]
    assert is_pid(state.running[issue.id].pid)
    assert MapSet.member?(state.claimed, issue.id)
    assert state.retry_attempts == %{}
    assert RunRegistry.load()[issue.id].epoch == 4
    assert RunRegistry.load()[issue.id].last_seq == 7

    send(pid, {:run_finished, issue.id, run_id, "normal"})

    assert eventually(fn -> not Map.has_key?(:sys.get_state(pid).running, issue.id) end)
    assert RunRegistry.load() == %{}

    state = :sys.get_state(pid)
    assert %{attempt: 1, identifier: "MT-ADOPT"} = state.retry_attempts[issue.id]

    GenServer.stop(pid)
    _ = root
  end

  test "a process-launched run's OS process reports events and finishes normally", %{root: root} do
    endpoint = Support.start_endpoint!()
    issue = Support.issue_fixture("issue-os", "MT-OS")
    run_id = "run-os-#{System.unique_integer([:positive])}"
    record = Support.record_run!(issue.id, run_id, identifier: issue.identifier, backend: "claude", epoch: 1)
    token = RunToken.sign(run_id, record.epoch)

    event = %{
      "seq" => 1,
      "type" => "finished",
      "data" =>
        RunEvents.encode(%{
          reason: "normal"
        })
    }

    body = Jason.encode!(%{events: [event]})
    script = Path.join(root, "post-run.sh")

    File.write!(script, """
    #!/bin/sh
    curl -sS -X POST '#{endpoint.url}/runner/v1/runs/#{run_id}/events' \\
      -H 'authorization: Bearer #{token}' \\
      -H 'content-type: application/json' \\
      --data '#{body}' >/dev/null
    exec sleep 30
    """)

    File.chmod!(script, 0o755)

    spec = %RunSpec{
      run_id: run_id,
      epoch: record.epoch,
      attempt: 0,
      issue: issue,
      backend: "claude",
      route: %{backend: "claude", effort: nil},
      controller_url: endpoint.url,
      token: token
    }

    assert {:ok, watcher, "process:" <> _pid = process_ref} =
             ProcessLauncher.start_process(spec,
               command: "#{script} {spec}",
               poll_interval_ms: 20,
               lost_grace_ms: 200
             )

    assert_receive {:orchestrator_message, {:run_finished, "issue-os", ^run_id, "normal"}}, 5_000
    monitor = Process.monitor(watcher)
    RunWatcher.finished(run_id, "normal")
    assert_receive {:DOWN, ^monitor, :process, ^watcher, :normal}, 2_000
    assert eventually(fn -> RunRegistry.load()[issue.id].last_seq == 1 end)
    ProcessLauncher.stop(process_ref)
  end

  test "a registered run that already finished normally is not adopted: it gets the continuation check", %{root: root} do
    issue = Support.issue_fixture("issue-finished", "MT-FIN")
    run_id = "run-finished"
    ref = "fake:finished"
    # Still alive (e.g. flushing): it is stopped, never adopted.
    FakeLauncher.set(ref, true)
    {:ok, spec_path} = RunSpec.write(%RunSpec{run_id: run_id, epoch: 3, issue: issue})

    fake_run!(issue, run_id, ref, root, %{attempt: 2, epoch: 3, finished: "normal"})

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "FinishedOrchestrator"))
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue.id)
    assert RunRegistry.load() == %{}
    assert %{attempt: 1, identifier: "MT-FIN", error: nil} = state.retry_attempts[issue.id]
    assert MapSet.member?(state.completed, issue.id)
    assert MapSet.member?(state.claimed, issue.id)
    assert eventually(fn -> FakeLauncher.stopped(ref) end)
    assert eventually(fn -> not File.exists?(spec_path) end)

    GenServer.stop(pid)
  end

  test "a registered run that finished with a failure gets the failure retry, without stopping a dead runner", %{root: root} do
    issue = Support.issue_fixture("issue-failed", "MT-FAILED")
    run_id = "run-failed"
    ref = "fake:failed"

    fake_run!(issue, run_id, ref, root, %{attempt: 2, epoch: 3, finished: "boom"})

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "FailedOrchestrator"))
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue.id)
    assert RunRegistry.load() == %{}
    assert %{attempt: 3, error: "agent exited: {:runner_failed, \"boom\"}"} = state.retry_attempts[issue.id]
    refute MapSet.member?(state.completed, issue.id)
    Process.sleep(50)
    refute FakeLauncher.stopped(ref)

    GenServer.stop(pid)
  end

  test "a dead runner whose outbox file holds a finished event is treated as finished, not interrupted", %{root: root} do
    issue = Support.issue_fixture("issue-outbox", "MT-OUTBOX")
    run_id = "run-outbox-finished"
    ref = "fake:outbox"
    dir = RunSpec.dir(run_id)
    File.mkdir_p!(dir)

    lines =
      [
        %{seq: 1, type: "heartbeat", data: RunEvents.encode(%{run_id: run_id})},
        %{seq: 2, type: "finished", data: RunEvents.encode(%{run_id: run_id, reason: "normal"})}
      ]
      |> Enum.map_join(&(Jason.encode!(&1) <> "\n"))

    File.write!(Path.join(dir, "outbox.jsonl"), lines)
    fake_run!(issue, run_id, ref, root, %{attempt: 1, epoch: 2})

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "OutboxOrchestrator"))
    state = :sys.get_state(pid)

    assert RunRegistry.load() == %{}
    assert %{attempt: 1, error: nil} = state.retry_attempts[issue.id]
    assert MapSet.member?(state.completed, issue.id)

    GenServer.stop(pid)
  end

  test "a process run whose watcher dies without a finished event is stopped before its retry", %{root: root} do
    issue = Support.issue_fixture("issue-watcher-down", "MT-WDOWN")
    run_id = "run-watcher-down"
    ref = "fake:watcher-down"
    FakeLauncher.set(ref, true)
    {:ok, spec_path} = RunSpec.write(%RunSpec{run_id: run_id, epoch: 1, issue: issue})

    fake_run!(issue, run_id, ref, root, %{attempt: 1, epoch: 1})

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "WatcherDownOrchestrator"))
    watcher = :sys.get_state(pid).running[issue.id].pid
    Process.exit(watcher, :kill)

    assert eventually(fn -> FakeLauncher.stopped(ref) end)
    assert eventually(fn -> not File.exists?(spec_path) end)
    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, issue.id)
    assert %{attempt: 2, error: "agent exited: :killed"} = state.retry_attempts[issue.id]

    GenServer.stop(pid)
  end

  test "a runner that failed to start is stopped, cleaned up and retried with its log tail", %{root: root} do
    issue = Support.issue_fixture("issue-launch-failed", "MT-LAUNCHF")
    run_id = "run-launch-failed"
    ref = "fake:launch-failed"
    FakeLauncher.set(ref, true)
    {:ok, spec_path} = RunSpec.write(%RunSpec{run_id: run_id, epoch: 1, issue: issue})
    fake_run!(issue, run_id, ref, root, %{attempt: 1, epoch: 1})

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "LaunchFailedOrchestrator"))
    watcher = :sys.get_state(pid).running[issue.id].pid
    Process.exit(watcher, {:launch_failed, "sh: symphony: not found\n"})

    assert eventually(fn -> FakeLauncher.stopped(ref) end)
    assert eventually(fn -> not File.exists?(spec_path) end)
    state = :sys.get_state(pid)
    assert %{attempt: 2, error: "runner failed to start: sh: symphony: not found"} = state.retry_attempts[issue.id]
    assert RunRegistry.load() == %{}

    GenServer.stop(pid)
  end

  test "process dispatch of a missing runner command returns at once and retries with the shell's error", %{root: root} do
    issue = Support.issue_fixture("issue-missing-cmd", "MT-MISSING")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    missing = Path.join(root, "no-such-runner")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_backend: "claude",
      agent_launcher: "process",
      agent_runner_command: "#{missing} {spec} {symphony} {run_id}",
      workspace_root: Path.join(root, "workspaces")
    )

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "MissingCommandOrchestrator"))

    assert eventually(fn -> Map.has_key?(:sys.get_state(pid).running, issue.id) end)
    assert %{launcher: ProcessLauncher, run_id: run_id} = :sys.get_state(pid).running[issue.id]

    assert eventually(fn -> Map.has_key?(:sys.get_state(pid).retry_attempts, issue.id) end, 150)
    %{error: error} = :sys.get_state(pid).retry_attempts[issue.id]
    assert error =~ "runner failed to start:"
    assert error =~ "no-such-runner"
    refute Map.has_key?(:sys.get_state(pid).running, issue.id)
    assert eventually(fn -> not File.exists?(RunSpec.path(run_id)) end)

    GenServer.stop(pid)
  end

  test "a cancelled process run is stopped off the orchestrator process", %{root: root} do
    issue = Support.issue_fixture("issue-cancel", "MT-CANCEL")
    run_id = "run-cancel"
    ref = "fake:cancel"
    FakeLauncher.set(ref, true)
    fake_run!(issue, run_id, ref, root, %{attempt: 1, epoch: 1})

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "CancelOrchestrator"))
    assert Map.has_key?(:sys.get_state(pid).running, issue.id)

    # The issue leaves the active states: reconciliation terminates the run.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Done"}])
    send(pid, :tick)

    assert eventually(fn -> FakeLauncher.stopped(ref) end)
    assert eventually(fn -> not Map.has_key?(:sys.get_state(pid).running, issue.id) end)

    GenServer.stop(pid)
  end

  test "process dispatch records the run before the runner starts, then its launcher reference" do
    issue = Support.issue_fixture("issue-dispatch", "MT-DISPATCH")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :run_launcher, FakeLauncher)
    FakeLauncher.on_start(:ok, self())

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "DispatchOrchestrator"))

    assert_receive {:fake_start, %RunSpec{run_id: run_id, token: token}, "pending:" <> pending_run_id}, 5_000
    assert pending_run_id == run_id
    assert is_binary(token)
    assert eventually(fn -> match?(%{ref: "fake:" <> ^run_id}, RunRegistry.load()[issue.id]) end)
    assert %{run_id: ^run_id, launcher: FakeLauncher} = :sys.get_state(pid).running[issue.id]

    GenServer.stop(pid)
  end

  test "a process launch failure forgets the pending run and retries with the launcher's error" do
    issue = Support.issue_fixture("issue-launch-fail", "MT-LFAIL")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :run_launcher, FakeLauncher)
    FakeLauncher.on_start({:error, {:runner_exited, "symphony: not found"}}, self())

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "LaunchFailOrchestrator"))

    assert_receive {:fake_start, %RunSpec{run_id: run_id}, "pending:" <> run_id}, 5_000
    assert eventually(fn -> Map.has_key?(:sys.get_state(pid).retry_attempts, issue.id) end)
    assert RunRegistry.load() == %{}
    assert :sys.get_state(pid).retry_attempts[issue.id].error =~ "symphony: not found"
    refute File.exists?(RunSpec.path(run_id))

    GenServer.stop(pid)
  end

  defp fake_run!(issue, run_id, ref, root, entry) do
    run_registry_entry(issue, run_id, Map.merge(%{launcher: FakeLauncher, ref: ref, metadata: metadata(issue, root)}, entry))
  end

  defp metadata(issue, root) do
    %{
      identifier: issue.identifier,
      issue_title: issue.title,
      labels: issue.labels,
      backend: "claude",
      worker_host: nil,
      workspace_path: Path.join(root, "workspaces/" <> issue.identifier),
      issue: issue
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp run_registry_entry(issue, run_id, entry) do
    :ok =
      RunRegistry.record(
        issue.id,
        Map.merge(
          %{
            run_id: run_id,
            attempt: 0,
            epoch: 1,
            launcher: RunLauncher.Local,
            ref: "ref",
            started_at_unix_ms: System.system_time(:millisecond),
            metadata: %{identifier: issue.identifier, issue: issue}
          },
          entry
        )
      )
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
