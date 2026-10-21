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

    assert {:ok, watcher, "process:" <> _pid} =
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
  end

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
