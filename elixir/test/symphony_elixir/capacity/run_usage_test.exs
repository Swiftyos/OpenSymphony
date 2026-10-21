defmodule SymphonyElixir.Capacity.RunUsageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Capacity.{Metrics, Prometheus, RunUsage, Sampler, SelfUsage, UsageReporter}
  alias SymphonyElixir.Config.Schema

  setup do
    Metrics.reset()
    RunUsage.reset()
    Application.put_env(:symphony_elixir, :capacity_proc_reader, fn _pid -> :error end)

    on_exit(fn ->
      RunUsage.reset()
      Application.delete_env(:symphony_elixir, :capacity_proc_reader)
    end)

    root = Path.join(System.tmp_dir!(), "self-usage-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp write!(root, path, contents) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
  end

  # utime stime cutime cstime are fields 14-17 and rss field 24 of /proc/<pid>/stat.
  defp stat(pid, comm, ppid, ticks, rss_pages) do
    "#{pid} (#{comm}) S #{ppid} 1 1 0 -1 0 0 0 0 0 #{ticks} 0 0 0 20 0 1 0 100 1000 #{rss_pages} 0"
  end

  describe "SelfUsage" do
    test "reads a namespaced cgroup v2 working set and CPU time", %{root: root} do
      write!(root, "proc/self/cgroup", "0::/\n")
      write!(root, "sys/fs/cgroup/cpu.stat", "usage_usec 2500000\nuser_usec 2000000\n")
      write!(root, "sys/fs/cgroup/memory.current", "1048576\n")
      write!(root, "sys/fs/cgroup/memory.stat", "anon 100\ninactive_file 524288\n")

      assert {:ok, %{cpu_seconds: 2.5, memory_bytes: 524_288, source: "cgroup_v2"}} = SelfUsage.read(root: root, pid: 1)
    end

    test "uses a symphony-run systemd unit's cgroup, without memory.stat", %{root: root} do
      unit = "/user.slice/user-1000.slice/user@1000.service/app.slice/symphony-run-abc.service"
      write!(root, "proc/self/cgroup", "0::#{unit}\n")
      write!(root, "sys/fs/cgroup#{unit}/cpu.stat", "usage_usec 1000000\n")
      write!(root, "sys/fs/cgroup#{unit}/memory.current", "4096")

      assert {:ok, %{cpu_seconds: 1.0, memory_bytes: 4096, source: "cgroup_v2"}} = SelfUsage.read(root: root, pid: 1)
    end

    test "reads cgroup v1 cpuacct and memory", %{root: root} do
      write!(root, "proc/self/cgroup", "4:memory:/\n3:cpu,cpuacct:/\n1:name=systemd:/\n")
      write!(root, "sys/fs/cgroup/cpu,cpuacct/cpuacct.usage", "3000000000\n")
      write!(root, "sys/fs/cgroup/memory/memory.usage_in_bytes", "8192\n")
      write!(root, "sys/fs/cgroup/memory/memory.stat", "total_inactive_file 4096\n")

      assert {:ok, %{cpu_seconds: 3.0, memory_bytes: 4096, source: "cgroup_v1"}} = SelfUsage.read(root: root, pid: 1)
    end

    test "a cgroup that is not the run's own falls back to the runner's process tree", %{root: root} do
      write!(root, "proc/self/cgroup", "0:cpu,cpuacct,memory:/system.slice/symphony.service\n0::/system.slice/symphony.service\n")
      write!(root, "sys/fs/cgroup/system.slice/symphony.service/cpu.stat", "usage_usec 99\n")
      write!(root, "sys/fs/cgroup/system.slice/symphony.service/memory.current", "99")

      # 10 is the runner, 11 and 12 its agent and a grandchild; 20 is someone else.
      write!(root, "proc/10/stat", stat(10, "beam.smp", 1, 100, 10))
      write!(root, "proc/11/stat", stat(11, "codex) (weird", 10, 50, 5))
      write!(root, "proc/12/stat", stat(12, "git", 11, 50, 1))
      write!(root, "proc/20/stat", stat(20, "other", 1, 1000, 1000))
      write!(root, "proc/30/stat", "garbage")
      write!(root, "proc/self/stat", stat(10, "beam.smp", 1, 100, 10))

      assert {:ok, %{cpu_seconds: 2.0, memory_bytes: 65_536, source: "proc"}} = SelfUsage.read(root: root, pid: 10)
    end

    test "nothing readable is :unavailable", %{root: root} do
      assert {:error, :unavailable} = SelfUsage.read(root: root, pid: 10)

      write!(root, "proc/self/cgroup", "0::/\n")
      write!(root, "sys/fs/cgroup/cpu.stat", "usage_usec nope\n")
      assert {:error, :unavailable} = SelfUsage.read(root: root, pid: 10)
    end

    test "the defaults read this host" do
      assert match?({:ok, %{source: _source}}, SelfUsage.read()) or SelfUsage.read() == {:error, :unavailable}
    end

    test "parse_stat rejects malformed lines" do
      assert :error = SelfUsage.parse_stat("1 no comm")
      assert :error = SelfUsage.parse_stat("1 (x) S")
      assert :error = SelfUsage.parse_stat("1 (x) S 1 1 1 0 -1 0 0 0 0 0 a 0 0 0 20 0 1 0 100 1000 1 0")
      assert {:ok, %{ppid: 1, ticks: 4, rss_pages: 0}} = SelfUsage.parse_stat("1 (x) S 1 1 1 0 -1 0 0 0 0 0 1 1 1 1 20 0 1 0 100 1000 -1 0")
    end
  end

  describe "UsageReporter" do
    test "reports CPU percent since the previous reading and memory to the outbox" do
      {:ok, readings} =
        Agent.start_link(fn ->
          [
            {:ok, %{cpu_seconds: 1.0, memory_bytes: 100, source: "proc"}},
            {:ok, %{cpu_seconds: 2.0, memory_bytes: 200, source: "proc"}},
            {:ok, %{cpu_seconds: 2.5, memory_bytes: 300, source: "cgroup_v2"}},
            {:error, :unavailable},
            {:ok, %{cpu_seconds: 3.0, memory_bytes: 400, source: "cgroup_v2"}},
            {:error, :unavailable}
          ]
        end)

      {:ok, clock} = Agent.start_link(fn -> 0 end)

      reader = fn ->
        Agent.get_and_update(readings, fn
          [last] -> {last, [last]}
          [next | rest] -> {next, rest}
        end)
      end

      tick = fn -> Agent.get_and_update(clock, &{&1, &1 + 2_000}) end

      log =
        capture_log(fn ->
          assert {:ok, pid} = UsageReporter.start(outbox: self(), run_id: "run-1", interval_ms: 20, reader: reader, clock: tick)

          # 1 CPU second over 2 wall seconds is 50% of one CPU.
          assert_receive {:"$gen_cast", {:append, "metrics", first}}, 1_000
          assert %{run_id: "run-1", cpu_percent: 50.0, cpu_seconds: 2.0, memory_bytes: 200, source: "proc"} = first

          # A new source has no comparable baseline.
          assert_receive {:"$gen_cast", {:append, "metrics", %{cpu_percent: nil, memory_bytes: 300}}}, 1_000
          # The failed reading is skipped and only logged.
          assert_receive {:"$gen_cast", {:append, "metrics", %{memory_bytes: 400, cpu_percent: cpu}}}, 1_000
          assert_in_delta cpu, 12.5, 0.001

          send(pid, :unexpected)
          assert :ok = UsageReporter.stop(pid)
        end)

      assert log =~ "Runner usage reading failed"
    end

    test "is off at a zero interval; bad readings and a stopped reporter are harmless" do
      assert :ignore = UsageReporter.start(outbox: self(), run_id: "r", interval_ms: 0)
      assert :ok = UsageReporter.stop(nil)

      capture_log(fn ->
        reader = fn -> raise "boom" end
        assert {:ok, pid} = UsageReporter.start(outbox: self(), run_id: "r", interval_ms: 10, reader: reader)
        Process.sleep(30)
        assert :ok = UsageReporter.stop(pid)
        assert :ok = UsageReporter.stop(pid)

        assert {:ok, _pid} = started = UsageReporter.start(outbox: self(), run_id: "r", interval_ms: 10, reader: fn -> :nonsense end)
        Process.sleep(30)
        assert :ok = UsageReporter.stop(started)
      end)

      refute_received {:"$gen_cast", _message}
    end

    test "the default reader measures this host" do
      capture_log(fn ->
        assert {:ok, pid} = UsageReporter.start(outbox: self(), run_id: "r", interval_ms: 10)
        Process.sleep(30)
        UsageReporter.stop(pid)
      end)
    end
  end

  describe "RunUsage" do
    test "stores reports by issue, ages them out and prunes issues no longer running" do
      assert :none = RunUsage.fetch("issue-1", 60_000)
      assert :none = RunUsage.fetch(nil, 60_000)

      RunUsage.mark_remote("issue-1")
      RunUsage.mark_remote("issue-1")
      RunUsage.mark_remote(nil)
      assert :remote = RunUsage.fetch("issue-1", 60_000)

      RunUsage.report("issue-1", %{"cpu_percent" => 12, "memory_bytes" => 1024, "source" => "cgroup_v2"})
      assert {:ok, %{cpu_percent: 12.0, memory_bytes: 1024, source: "cgroup_v2"}} = RunUsage.fetch("issue-1", 60_000)
      assert :remote = RunUsage.fetch("issue-1", -1)

      RunUsage.report("issue-2", %{memory_bytes: 1, cpu_percent: nil, source: "made-up"})
      assert {:ok, %{cpu_percent: nil, source: "other"}} = RunUsage.fetch("issue-2", 60_000)

      # Without a memory figure a report is ignored.
      RunUsage.report("issue-3", %{cpu_percent: 1})
      RunUsage.report(nil, %{memory_bytes: 1})
      assert :none = RunUsage.fetch("issue-3", 60_000)

      RunUsage.prune(["issue-2"])
      assert :none = RunUsage.fetch("issue-1", 60_000)
      assert {:ok, _sample} = RunUsage.fetch("issue-2", 60_000)

      body = Prometheus.render()
      assert body =~ ~s(symphony_run_usage_reports_total{source="cgroup_v2"} 1)
      assert body =~ ~s(symphony_run_usage_reports_total{source="other"} 1)
    end
  end

  describe "the sampler with runner reports" do
    test "uses a fresh report as the run's sample and never matches a runner-hosted pid against ps" do
      {:ok, settings} = Schema.parse(%{"capacity" => %{"sample_interval_ms" => 0}})
      parent = self()

      RunUsage.report("pod-run", %{cpu_percent: 150.0, memory_bytes: 2_000_000, source: "cgroup_v2"})
      RunUsage.mark_remote("pod-pending")

      snapshot = %{
        running: [
          %{issue_id: "pod-run", identifier: "POD-1", backend: "claude", stage: "implement", agent_server_pid: 100},
          # Its pid is the pod's own, which may be any process on this host.
          %{issue_id: "pod-pending", identifier: "POD-2", backend: "codex", agent_server_pid: 200},
          %{issue_id: "local", identifier: "LOCAL-1", backend: "codex", stage: "review", agent_server_pid: 300}
        ]
      }

      runner = fn command, _args, _opts ->
        send(parent, {:ran, command})
        {"200 1 9000 00:00:09.0\n300 1 1000 00:00:01.0\n", 0}
      end

      assert :ok = Sampler.sample(settings: settings, snapshot_fun: fn -> snapshot end, command_runner: runner)
      assert_receive {:ran, "ps"}

      body = Prometheus.render()
      assert body =~ ~s(symphony_runs_sampled{} 2)
      assert body =~ ~s(symphony_run_cpu_percent{backend="claude",issue="POD-1",stage="implement"} 150)
      assert body =~ ~s(symphony_run_memory_bytes{backend="claude",issue="POD-1",stage="implement"} 2000000)
      assert body =~ ~s(symphony_run_memory_bytes{backend="codex",issue="LOCAL-1",stage="review"} 1024000)
      refute body =~ "POD-2"
      assert body =~ ~s(symphony_run_cpu_percent_distribution_count{} 1)
    end

    test "with only runner-hosted runs no command runs at all, and ended runs are pruned" do
      {:ok, settings} = Schema.parse(%{"capacity" => %{"sample_interval_ms" => 0}})
      RunUsage.report("pod-run", %{cpu_percent: nil, memory_bytes: 5, source: "proc"})
      RunUsage.report("ended", %{cpu_percent: nil, memory_bytes: 5, source: "proc"})

      snapshot = %{running: [%{issue_id: "pod-run", identifier: "POD-1", backend: "codex"}]}
      runner = fn _command, _args, _opts -> flunk("no command expected") end

      assert :ok = Sampler.sample(settings: settings, snapshot_fun: fn -> snapshot end, command_runner: runner)
      assert Prometheus.render() =~ ~s(symphony_run_memory_bytes{backend="codex",issue="POD-1",stage=""} 5)
      assert :none = RunUsage.fetch("ended", 60_000)
    end
  end
end
