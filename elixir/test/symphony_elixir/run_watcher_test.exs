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

  test "a launched runner gone at the startup check exits {:launch_failed, log_tail}", %{run_id: run_id} do
    dir = Path.join(System.tmp_dir!(), "run-watcher-log-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    log = Path.join(dir, "runner.log")
    File.write!(log, String.duplicate("x", 3_000) <> "sh: no-such-runner: not found\n")

    assert {:ok, watcher} =
             RunWatcher.start(%{run_id: run_id, issue_id: "issue-1"}, "fake:" <> run_id,
               launcher: FakeLauncher,
               log: log,
               startup_check_ms: 20,
               poll_interval_ms: 10,
               lost_grace_ms: 10_000
             )

    monitor = Process.monitor(watcher)
    assert_receive {:DOWN, ^monitor, :process, ^watcher, {:launch_failed, tail}}, 1_000
    assert byte_size(tail) == 2_000
    assert tail =~ "not found"

    # No log at all still fails the launch, with an empty tail.
    other = run_id <> "-nolog"

    assert {:ok, watcher} =
             RunWatcher.start(%{run_id: other, issue_id: "issue-1"}, "fake:" <> other,
               launcher: FakeLauncher,
               log: Path.join(dir, "missing.log"),
               startup_check_ms: 0
             )

    monitor = Process.monitor(watcher)
    assert_receive {:DOWN, ^monitor, :process, ^watcher, {:launch_failed, ""}}, 1_000

    # A short log is kept whole.
    short = run_id <> "-short"
    File.write!(Path.join(dir, "short.log"), "exit 127\n")

    assert {:ok, watcher} =
             RunWatcher.start(%{run_id: short, issue_id: "issue-1"}, "fake:" <> short,
               launcher: FakeLauncher,
               log: Path.join(dir, "short.log"),
               startup_check_ms: 0
             )

    monitor = Process.monitor(watcher)
    assert_receive {:DOWN, ^monitor, :process, ^watcher, {:launch_failed, "exit 127\n"}}, 1_000
  end

  test "a launched runner alive at the startup check is then polled as usual", %{run_id: run_id} do
    ref = "fake:" <> run_id
    FakeLauncher.set(ref, true)

    assert {:ok, watcher} =
             RunWatcher.start(%{run_id: run_id, issue_id: "issue-1"}, ref,
               launcher: FakeLauncher,
               log: "/nonexistent/runner.log",
               startup_check_ms: 20,
               poll_interval_ms: 10,
               lost_grace_ms: 30
             )

    monitor = Process.monitor(watcher)
    refute_receive {:DOWN, ^monitor, _, _, _}, 100
    # Gone after a good start is a lost runner, not a failed launch.
    FakeLauncher.set(ref, false)
    assert_receive {:DOWN, ^monitor, :process, ^watcher, :runner_lost}, 1_000
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
    pid = spawn(fn -> Process.sleep(5_000) end)
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

  defmodule StatusLauncher do
    def status("fake:gone-" <> _), do: {:gone, {:pod_failed, "Evicted"}}
    def status(_ref), do: {:unknown, :api_down}
    def stop(_ref), do: :ok
  end

  test "a launcher's status/1 is used, an unknown status keeps polling and a gone reason is the exit", %{run_id: run_id} do
    assert {:ok, watcher} =
             RunWatcher.start(%{run_id: run_id}, "fake:" <> run_id, launcher: StatusLauncher, poll_interval_ms: 10, lost_grace_ms: 20)

    log = ExUnit.CaptureLog.capture_log(fn -> Process.sleep(60) end)
    assert Process.alive?(watcher)
    assert log =~ "Run watcher could not check"
    RunWatcher.stop(watcher)

    assert {:ok, watcher} =
             RunWatcher.start(%{run_id: run_id}, "fake:gone-" <> run_id, launcher: StatusLauncher, poll_interval_ms: 10, lost_grace_ms: 20)

    monitor = Process.monitor(watcher)

    ExUnit.CaptureLog.capture_log(fn ->
      assert_receive {:DOWN, ^monitor, :process, ^watcher, {:pod_failed, "Evicted"}}, 2_000
    end)
  end

  test "a status function that raises is treated as gone", %{run_id: run_id} do
    assert {:ok, watcher} =
             RunWatcher.start(%{run_id: run_id}, "fake:" <> run_id,
               launcher: StatusLauncher,
               status: fn -> raise "no" end,
               poll_interval_ms: 10,
               lost_grace_ms: 20
             )

    monitor = Process.monitor(watcher)

    ExUnit.CaptureLog.capture_log(fn ->
      assert_receive {:DOWN, ^monitor, :process, ^watcher, :runner_lost}, 2_000
    end)
  end

  test "a second watcher for the same run is refused", %{run_id: run_id} do
    FakeLauncher.set("fake:" <> run_id, true)
    assert {:ok, watcher} = RunWatcher.start(%{run_id: run_id}, "fake:" <> run_id, launcher: FakeLauncher, poll_interval_ms: 10)

    assert {:error, {:already_watched, ^watcher}} =
             RunWatcher.start(%{run_id: run_id}, "fake:" <> run_id, launcher: FakeLauncher, poll_interval_ms: 10)

    assert Process.alive?(watcher)
  end
end
