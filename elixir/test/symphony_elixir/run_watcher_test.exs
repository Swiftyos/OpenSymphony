defmodule SymphonyElixir.RunWatcherTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.RunWatcher

  defmodule RaisingLauncher do
    def alive?(_ref), do: raise("no")
    def stop(_ref), do: :ok
  end

  defmodule FakeLauncher do
    @table :symphony_run_watcher_test

    def setup do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set])
      end

      :ets.delete_all_objects(@table)
      :ok
    end

    def set(ref, alive?), do: :ets.insert(@table, {ref, alive?})

    def alive?(ref) do
      case :ets.lookup(@table, ref) do
        [{^ref, alive?}] -> alive?
        [] -> false
      end
    rescue
      ArgumentError -> false
    end

    def stop(ref) do
      if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {ref, false})
      :ok
    end
  end

  setup do
    FakeLauncher.setup()
    run_id = "run-watcher-#{System.unique_integer([:positive])}"
    on_exit(fn -> RunWatcher.stop(run_id) end)
    %{run_id: run_id}
  end

  test "a finished event exits the watcher with that run's reason", %{run_id: run_id} do
    FakeLauncher.set("fake:" <> run_id, true)

    assert {:ok, watcher} =
             RunWatcher.start(%{run_id: run_id, issue_id: "issue-1"}, "fake:" <> run_id,
               launcher: FakeLauncher,
               poll_interval_ms: 10,
               lost_grace_ms: 50
             )

    monitor = Process.monitor(watcher)
    assert %DateTime{} = RunWatcher.last_seen(run_id)

    assert :ok = RunWatcher.finished(run_id, "normal")
    assert_receive {:DOWN, ^monitor, :process, ^watcher, :normal}
    assert RunWatcher.last_seen(run_id) == nil
  end

  test "a non-normal finished reason becomes {:runner_failed, reason}", %{run_id: run_id} do
    FakeLauncher.set("fake:" <> run_id, true)

    assert {:ok, watcher} =
             RunWatcher.start(%{run_id: run_id}, "fake:" <> run_id,
               launcher: FakeLauncher,
               poll_interval_ms: 10,
               lost_grace_ms: 50
             )

    monitor = Process.monitor(watcher)
    GenServer.cast(watcher, {:finished, "boom"})
    assert_receive {:DOWN, ^monitor, :process, ^watcher, {:runner_failed, "boom"}}
  end

  test "activity moves the last-seen timestamp", %{run_id: run_id} do
    FakeLauncher.set("fake:" <> run_id, true)

    assert {:ok, watcher} =
             RunWatcher.start(%{run_id: run_id}, "fake:" <> run_id,
               launcher: FakeLauncher,
               poll_interval_ms: 0,
               lost_grace_ms: 50
             )

    first = RunWatcher.last_seen(run_id)
    Process.sleep(5)
    assert :ok = RunWatcher.touch(run_id)
    assert :ok = RunWatcher.touch(run_id)
    second = RunWatcher.last_seen(run_id)
    assert DateTime.compare(second, first) in [:gt, :eq]

    send(watcher, :ignored)
    Process.sleep(20)
    assert Process.alive?(watcher)

    assert :ok = RunWatcher.stop(run_id)
    assert :ok = RunWatcher.touch(run_id)
    assert :ok = RunWatcher.finished(run_id, "normal")
    RunWatcher.stop(watcher)
  end

  test "a process gone without a finished event exits :runner_lost after the grace", %{run_id: run_id} do
    FakeLauncher.set("fake:" <> run_id, false)

    assert {:ok, watcher} =
             RunWatcher.start(%{run_id: run_id}, "fake:" <> run_id,
               launcher: FakeLauncher,
               poll_interval_ms: 5,
               lost_grace_ms: 20
             )

    monitor = Process.monitor(watcher)
    assert_receive {:DOWN, ^monitor, :process, ^watcher, :runner_lost}, 1_000
  end

  test "a run that stays alive keeps the watcher running", %{run_id: run_id} do
    FakeLauncher.set("fake:" <> run_id, true)

    assert {:ok, watcher} =
             RunWatcher.start(%{run_id: run_id}, "fake:" <> run_id,
               launcher: FakeLauncher,
               poll_interval_ms: 10,
               lost_grace_ms: 20
             )

    Process.sleep(50)
    assert Process.alive?(watcher)
    assert :ok = RunWatcher.stop(run_id)
    refute Process.alive?(watcher)
    assert :ok = RunWatcher.stop(run_id)
  end

  test "a launcher that raises is treated as gone" do
    run_id = "run-raises-#{System.unique_integer([:positive])}"

    assert {:ok, watcher} =
             RunWatcher.start(%{run_id: run_id}, "raising", launcher: RaisingLauncher, poll_interval_ms: 5, lost_grace_ms: 10)

    monitor = Process.monitor(watcher)
    assert_receive {:DOWN, ^monitor, :process, ^watcher, :runner_lost}, 1_000
  end

  test "last_seen degrades when the watcher is the calling process", %{run_id: run_id} do
    Registry.register(RunWatcher.registry(), run_id, nil)
    assert RunWatcher.last_seen(run_id) == nil
  end

  test "stopping a pid that is not a GenServer is harmless" do
    pid = spawn(fn -> Process.sleep(1_000) end)
    assert :ok = RunWatcher.stop(pid)
    Process.exit(pid, :kill)
  end

  test "lookups and stops for unknown runs are no-ops" do
    assert :ok = RunWatcher.touch("missing")
    assert :ok = RunWatcher.touch(nil)
    assert :ok = RunWatcher.finished("missing", "normal")
    assert :ok = RunWatcher.finished(nil, nil)
    assert RunWatcher.last_seen("missing") == nil
    assert RunWatcher.last_seen(nil) == nil
    assert :ok = RunWatcher.stop("missing")
    assert :ok = RunWatcher.stop(nil)
    assert RunWatcher.registry() == SymphonyElixir.RunWatcher.Registry
    assert RunWatcher.supervisor() == SymphonyElixir.RunWatcher.Supervisor
  end

  test "a watcher can start without the application supervisor", %{run_id: run_id} do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, RunWatcher.Supervisor)

    try do
      assert {:ok, watcher} =
               RunWatcher.start(%{run_id: run_id}, "fake:" <> run_id,
                 launcher: FakeLauncher,
                 poll_interval_ms: 10,
                 lost_grace_ms: 50
               )

      assert :ok = RunWatcher.stop(run_id)
      refute Process.alive?(watcher)
      assert {:ok, default_watcher} = RunWatcher.start(%{run_id: run_id}, "fake:" <> run_id)
      RunWatcher.stop(default_watcher)
    after
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, RunWatcher.Supervisor)
    end
  end
end
