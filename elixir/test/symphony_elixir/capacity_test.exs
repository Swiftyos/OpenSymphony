defmodule SymphonyElixir.CapacityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Capacity.{Metrics, Prometheus, Sampler}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Client

  describe "capacity config" do
    test "defaults to a 30 second sample interval and accepts 0" do
      assert {:ok, settings} = Schema.parse(%{})
      assert settings.capacity.sample_interval_ms == 30_000

      assert {:ok, settings} = Schema.parse(%{"capacity" => %{"sample_interval_ms" => "0"}})
      assert settings.capacity.sample_interval_ms == 0

      assert {:ok, settings} = Schema.parse(%{"capacity" => %{"sample_interval_ms" => 5_000}})
      assert settings.capacity.sample_interval_ms == 5_000

      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"capacity" => %{"sample_interval_ms" => -1}})

      assert message =~ "capacity.sample_interval_ms must be greater than or equal to 0"
    end
  end

  describe "metric storage and rendering" do
    setup do
      Metrics.reset()
      :ok
    end

    test "start_link can be started under a supervisor alongside the application instance" do
      opts = [name: :capacity_metrics_test]
      {:ok, pid} = start_supervised(%{id: :capacity_metrics_test, start: {Metrics, :start_link, [opts]}})
      assert Process.alive?(pid)
      assert Metrics.snapshot() == %{counters: [], gauges: [], histograms: []}
    end

    test "records labelled counters, gauges and histograms" do
      assert :ok = Metrics.record_counter("symphony_git_operations_total", operation: "workspace_create", outcome: "ok")
      assert :ok = Metrics.record_counter("symphony_git_operations_total", %{operation: "workspace_create", outcome: "ok"}, 2)
      assert :ok = Metrics.set_gauge("symphony_run_cpu_percent", [issue: "PAY-1", backend: "codex", stage: "implement"], 12.5)
      assert :ok = Metrics.set_gauge("symphony_run_tokens_per_minute", %{}, 3.25)
      assert :ok = Metrics.record_histogram("symphony_git_operation_duration_seconds", [operation: "workspace_create"], 0.02)
      assert :ok = Metrics.record_histogram("symphony_run_cpu_percent_distribution", [], 9_999)
      assert :ok = Metrics.record_histogram("symphony_run_memory_bytes_distribution", [], 1_024)

      snapshot = Metrics.snapshot()
      assert Enum.any?(snapshot.counters, &(&1.name == "symphony_git_operations_total" and &1.value == 3))
      assert Enum.any?(snapshot.gauges, &(&1.name == "symphony_run_cpu_percent" and &1.value == 12.5))
      assert Enum.any?(snapshot.histograms, &(&1.name == "symphony_git_operation_duration_seconds"))

      body = Prometheus.render()
      assert body =~ "# HELP symphony_linear_requests_total Linear GraphQL requests made by Symphony."
      assert body =~ "# TYPE symphony_linear_request_duration_seconds histogram"
      assert body =~ ~s(symphony_git_operations_total{operation="workspace_create",outcome="ok"} 3)
      assert body =~ ~s(symphony_run_cpu_percent{backend="codex",issue="PAY-1",stage="implement"} 12.5)

      assert body =~
               ~s(symphony_git_operation_duration_seconds_bucket{le="0.05",operation="workspace_create"} 1)

      assert body =~ ~s(symphony_run_cpu_percent_distribution_bucket{le="+Inf"} 1)
      assert body =~ ~s(le="1073741824"} 1)
      assert body =~ ~s(symphony_run_tokens_per_minute{} 3.25)
    end

    test "escapes label values and handles empty snapshots" do
      Metrics.record_counter("symphony_linear_requests_total", operation: "quote\"slash\\newline\n", outcome: "ok")
      body = Prometheus.render()
      assert body =~ ~s(operation="quote\\"slash\\\\newline\\n")

      Metrics.reset()
      assert Metrics.snapshot() == %{counters: [], gauges: [], histograms: []}
      assert Metrics.delete_gauges(["symphony_run_cpu_percent"]) == :ok
      assert Metrics.histogram_buckets("symphony_run_cpu_percent_distribution") == [0, 25, 50, 100, 200, 400, 800]
    end

    test "all recording functions are safe before the storage process starts" do
      metrics = Process.whereis(Metrics)
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Metrics)

      on_exit(fn ->
        if Process.whereis(Metrics) == nil do
          {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, Metrics)
        else
          assert is_pid(metrics)
        end
      end)

      assert Metrics.record_counter("symphony_linear_requests_total", operation: "x", outcome: "ok") == :ok
      assert Metrics.set_gauge("symphony_run_cpu_percent", [issue: "X-1"], 1) == :ok
      assert Metrics.delete_gauges(["symphony_run_cpu_percent"]) == :ok
      assert Metrics.record_histogram("symphony_linear_request_duration_seconds", [operation: "x"], 0.1) == :ok
      assert Metrics.snapshot() == %{counters: [], gauges: [], histograms: []}
      assert Metrics.reset() == :ok
    end
  end

  describe "Linear instrumentation" do
    setup do
      Metrics.reset()
      :ok
    end

    test "counts requests by parsed operation and records rate-limit headers" do
      request = fn payload, _headers ->
        send(self(), {:linear_payload, payload})

        {:ok,
         %{
           status: 200,
           body: %{"data" => %{"ok" => true}},
           headers: [
             {"X-RateLimit-Requests-Remaining", "42"},
             {"x-ratelimit-complexity-remaining", "7"},
             {"x-ratelimit-requests-limit", "100"}
           ]
         }}
      end

      assert {:ok, %{"data" => _}} =
               Client.graphql("query SymphonyCreateComment { viewer { id } }", %{}, request_fun: request)

      assert_receive {:linear_payload, %{"query" => query}}
      assert query =~ "SymphonyCreateComment"

      body = Prometheus.render()
      assert body =~ ~s(symphony_linear_requests_total{operation="SymphonyCreateComment",outcome="ok"} 1)
      assert body =~ ~s(symphony_linear_rate_limit_remaining{kind="requests"} 42)
      assert body =~ ~s(symphony_linear_rate_limit_remaining{kind="complexity"} 7)
      assert body =~ ~s(symphony_linear_request_duration_seconds_count{operation="SymphonyCreateComment"} 1)
    end

    test "classifies errors and rate limits, falls back to operationName, and ignores bad headers" do
      response = fn status ->
        fn _payload, _headers ->
          {:ok, %{status: status, body: %{}, headers: %{"x-ratelimit-requests-remaining" => "not-a-number"}}}
        end
      end

      assert {:error, {:linear_api_status, 429}} =
               Client.graphql("{ viewer { id } }", %{}, request_fun: response.(429), operation_name: "ExplicitOp")

      assert {:error, {:linear_api_status, 500}} =
               Client.graphql("mutation SymphonyShip { viewer { id } }", %{}, request_fun: response.(500))

      assert {:error, {:linear_api_request, :timeout}} =
               Client.graphql("subscription SymphonyWatch { viewer { id } }", %{}, request_fun: fn _, _ -> {:error, :timeout} end)

      assert {:error, {:linear_api_request, :down}} =
               Client.graphql("{ viewer { id } }", %{}, request_fun: fn _, _ -> {:error, :down} end)

      body = Prometheus.render()
      assert body =~ ~s(symphony_linear_requests_total{operation="ExplicitOp",outcome="rate_limited"} 1)
      assert body =~ ~s(symphony_linear_requests_total{operation="SymphonyShip",outcome="error"} 1)
      assert body =~ ~s(symphony_linear_requests_total{operation="SymphonyWatch",outcome="error"} 1)
      assert body =~ ~s(symphony_linear_requests_total{operation="unknown",outcome="error"} 1)
      refute body =~ ~s(symphony_linear_rate_limit_remaining{kind="requests"})
    end
  end

  describe "git instrumentation" do
    setup do
      Metrics.reset()
      :ok
    end

    test "records cache and workspace-create operations" do
      root = Path.join(System.tmp_dir!(), "symphony-capacity-git-#{System.unique_integer([:positive])}")
      source = Path.join(root, "source")
      workspace_root = Path.join(root, "workspaces")

      try do
        File.mkdir_p!(source)
        File.write!(Path.join(source, "README.md"), "capacity git\n")
        System.cmd("git", ["-C", source, "init", "-b", "main"])
        System.cmd("git", ["-C", source, "config", "user.name", "Test User"])
        System.cmd("git", ["-C", source, "config", "user.email", "test@example.com"])
        System.cmd("git", ["-C", source, "add", "README.md"])
        System.cmd("git", ["-C", source, "commit", "-m", "initial"])

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_project_slug: nil,
          tracker_projects: [%{slug: "project-a", repo: source}],
          workspace_root: workspace_root
        )

        issue = %Issue{identifier: "PI-1", project_slug: "project-a"}
        assert {:ok, _workspace} = Workspace.create_for_issue(issue)

        body = Prometheus.render()
        assert body =~ ~s(symphony_git_operations_total{operation="cache_clone_or_fetch",outcome="ok"} 1)
        assert body =~ ~s(symphony_git_operations_total{operation="workspace_create",outcome="ok"} 1)
        assert body =~ ~s(symphony_git_operation_duration_seconds_count{operation="workspace_create"} 1)
      after
        File.rm_rf(root)
      end
    end
  end

  describe "container stats parsing" do
    test "parses docker per-line JSON and podman arrays" do
      docker =
        ~s({"BlockIO":"0B / 0B","CPUPerc":"12.50%","Container":"abc","ID":"abc","MemPerc":"1.00%",) <>
          ~s("MemUsage":"100MiB / 2GiB","Name":"symphony-docker-123","NetIO":"0B / 0B"}) <>
          "\n" <>
          ~s({"Name":"weird","CPUPerc":"abc","MemUsage":"unknown"})

      assert {:ok, [docker_sample, weird]} = Sampler.parse_container_stats(docker)
      assert docker_sample.name == "symphony-docker-123"
      assert_in_delta docker_sample.cpu_percent, 12.5, 0.01
      assert docker_sample.memory_bytes == 100 * 1024 * 1024
      assert weird.cpu_percent == 0.0
      assert weird.memory_bytes == 0

      podman =
        Jason.encode!([
          %{"name" => "symphony-podman-1", "cpu" => "3.5%", "mem_usage" => "256MiB / 1GiB", "mem_usage_bytes" => 268_435_456},
          %{"Name" => "symphony-podman-2", "CPUPerc" => "1.0%", "MemUsage" => "1.5GB / 2GB"}
        ])

      assert {:ok, [first, second]} = Sampler.parse_container_stats(podman)
      assert first.name == "symphony-podman-1"
      assert first.memory_bytes == 268_435_456
      assert_in_delta first.cpu_percent, 3.5, 0.01
      assert second.memory_bytes == 1_500_000_000
    end

    test "parses every supported memory unit and alternate field names" do
      rows = [
        %{"Names" => "b", "cpu_percent" => 1, "memory_bytes" => 10},
        %{"names" => "kb", "cpu" => 2, "mem_usage" => "2KB / 1GiB"},
        %{"container" => "kib", "cpu" => 3, "MemUsage" => "2KiB / 1GiB"},
        %{"Name" => "mb", "cpu" => 4, "mem_usage" => "2MB / 1GiB"},
        %{"Name" => "gb", "cpu" => 5, "MemUsage" => "2GB / 1GiB"},
        %{"Name" => "gib", "cpu" => 6, "MemUsage" => "2GiB / 1GiB"},
        %{"Name" => "tb", "cpu" => 7, "mem" => "2TB / 1GiB"},
        %{"Name" => "tib", "cpu" => 8, "memory" => "2TiB / 1GiB"},
        %{"Name" => "bytes", "cpu" => "9%", "MemUsage" => "2B / 1GiB"},
        %{"Name" => "blank", "cpu" => 1, "MemUsage" => ""},
        %{"Name" => "float-memory", "memory_bytes" => 1.5},
        %{"Name" => "string-memory", "memory_bytes" => "2MiB"},
        %{"Name" => "unitless", "MemUsage" => "2 / 1GiB"},
        %{"Name" => "unknown-unit", "MemUsage" => "2XB / 1GiB"},
        %{"Name" => "numeric-memory", "MemUsage" => 123},
        %{"Name" => "no-memory"}
      ]

      assert {:ok, samples} = Sampler.parse_container_stats(Jason.encode!(rows))

      assert Enum.map(samples, & &1.memory_bytes) == [
               10,
               2_000,
               2048,
               2_000_000,
               2_000_000_000,
               2 * 1024 * 1024 * 1024,
               2_000_000_000_000,
               2 * 1024 * 1024 * 1024 * 1024,
               2,
               0,
               1,
               2 * 1024 * 1024,
               2,
               2,
               123,
               0
             ]

      assert Enum.at(samples, 8).cpu_percent == 9.0
    end

    test "reports malformed output instead of raising" do
      assert Sampler.parse_container_stats("") == {:ok, []}
      assert {:error, _reason} = Sampler.parse_container_stats("[")
      assert {:error, _reason} = Sampler.parse_container_stats("not json")
      assert {:error, :unexpected_container_stats_shape} = Sampler.parse_container_stats("[1]")
      assert {:error, :unexpected_container_stats_shape} = Sampler.parse_container_stats("1")
      assert Sampler.parse_container_stats(nil) == {:error, :invalid_container_stats}
    end
  end

  describe "process tree aggregation" do
    test "parses ps output and sums roots plus descendants, skipping bad lines" do
      output = """
      PID PPID RSS %CPU
      100 1 1000 1.5
      101 100 2000 2.5
      102 101 3000 3.0
      200 1 4000 4.0
      bad row
      201 x 1 1
      202 1 x 1
      """

      assert {:ok, processes} = Sampler.parse_ps(output)
      assert processes[100] == %{ppid: 1, rss_kb: 1000.0, cpu_percent: 1.5}

      assert %{
               100 => %{cpu_percent: 7.0, memory_bytes: 6_144_000},
               200 => %{cpu_percent: 4.0, memory_bytes: 4_096_000}
             } = Sampler.aggregate_processes(processes, [100, 200])

      assert Sampler.parse_ps(nil) == {:error, :invalid_ps_output}
    end

    test "does not loop on cycles and tolerates missing roots" do
      processes = %{
        1 => %{ppid: 2, rss_kb: 1, cpu_percent: 1},
        2 => %{ppid: 1, rss_kb: 2, cpu_percent: 2}
      }

      result = Sampler.aggregate_processes(processes, [1, 99])
      assert result[1] == %{cpu_percent: 3.0, memory_bytes: 3_072}
      assert result[99] == %{cpu_percent: 0.0, memory_bytes: 0}
    end
  end

  describe "token rate" do
    test "uses runtime or started_at to compute tokens per minute" do
      assert Sampler.token_rate_per_minute(%{agent_total_tokens: 120, runtime_seconds: 60}) == 120.0
      assert Sampler.token_rate_per_minute(%{"agent_total_tokens" => "60", "runtime_seconds" => 120}) == 30.0
      assert Sampler.token_rate_per_minute(%{agent_total_tokens: 50, runtime_seconds: 0, started_at: DateTime.add(DateTime.utc_now(), -60, :second)}) == 50.0

      started_at = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.to_iso8601()
      assert_in_delta Sampler.token_rate_per_minute(%{agent_total_tokens: 10, started_at: started_at}), 10.0, 0.2

      assert Sampler.token_rate_per_minute(%{agent_total_tokens: 10, started_at: "garbage"}) == nil
      assert Sampler.token_rate_per_minute(%{agent_total_tokens: "100"}) == nil
      assert Sampler.token_rate_per_minute(%{agent_total_tokens: "bogus", runtime_seconds: 1}) == nil
      assert Sampler.token_rate_per_minute(%{agent_total_tokens: 10, runtime_seconds: -1}) == nil
      assert Sampler.token_rate_per_minute(%{}) == nil
    end
  end

  describe "sampler" do
    setup do
      Metrics.reset()
      :ok
    end

    test "selects podman and docker stats arguments" do
      assert Sampler.stats_args("/usr/bin/podman") == ["stats", "--no-stream", "--format", "json"]
      assert Sampler.stats_args("docker") == ["stats", "--no-stream", "--format", "{{json .}}"]
    end

    test "samples containers once and maps them back to issues" do
      workspace = Path.join(System.tmp_dir!(), "symphony-capacity-container")
      container = SymphonyElixir.Sandbox.container_name(workspace)
      settings = docker_settings("podman")

      snapshot = %{
        running: [
          %{
            issue_id: "issue-1",
            identifier: "PAY-1",
            backend: "codex",
            stage: "implement",
            workspace_path: workspace,
            agent_total_tokens: 120,
            runtime_seconds: 60
          },
          %{
            issue_id: "issue-2",
            identifier: "PAY-2",
            backend: "claude",
            stage: "review",
            workspace_path: nil
          }
        ]
      }

      runner = fn command, args, opts ->
        send(self(), {:stats, command, args, opts})

        {Jason.encode!([
           %{"name" => container, "cpu" => "25.0%", "mem_usage" => "512MiB / 1GiB"},
           %{"name" => "unrelated", "cpu" => "1.0%", "mem_usage" => "1MiB / 1GiB"}
         ]), 0}
      end

      assert :ok = Sampler.sample(settings: settings, snapshot_fun: fn -> snapshot end, command_runner: runner)
      assert_receive {:stats, "podman", ["stats", "--no-stream", "--format", "json"], _opts}

      body = Prometheus.render()
      assert body =~ ~s(symphony_runs_sampled{} 1)
      assert body =~ ~s(symphony_run_cpu_percent{backend="codex",issue="PAY-1",stage="implement"} 25.0)
      assert body =~ ~s(symphony_run_memory_bytes{backend="codex",issue="PAY-1",stage="implement"} 536870912)
      assert body =~ ~s(symphony_run_tokens_per_minute{backend="codex",issue="PAY-1"} 120.0)
      assert body =~ ~s(symphony_run_memory_bytes_distribution_count{} 1)
    end

    test "samples local process trees and skips remote workers" do
      settings = no_sandbox_settings()

      ps = """
      PID PPID RSS %CPU
      100 1 1000 1.5
      101 100 2000 2.5
      102 101 3000 3.0
      200 1 4000 4.0
      300 1 5000 5.0
      """

      snapshot = %{
        running: [
          %{identifier: "PAY-1", backend: "codex", stage: "implement", agent_server_pid: "100", agent_total_tokens: 60, runtime_seconds: 60},
          %{identifier: "PAY-2", backend: "claude", stage: "review", agent_server_pid: 200, agent_total_tokens: 30, runtime_seconds: 60},
          %{identifier: "BAD-1", backend: "codex", agent_server_pid: "abc"},
          %{identifier: "BAD-2", backend: "codex", agent_server_pid: %{}},
          %{identifier: "REMOTE-1", backend: "codex", agent_server_pid: "300", worker_host: "worker-1"}
        ]
      }

      runner = fn command, args, opts ->
        send(self(), {:ps, command, args, opts})
        {ps, 0}
      end

      assert :ok = Sampler.sample(settings: settings, snapshot_fun: fn -> snapshot end, command_runner: runner)
      assert_receive {:ps, "ps", ["-o", "pid,ppid,rss,%cpu", "-ax"], _opts}

      body = Prometheus.render()
      assert body =~ ~s(symphony_runs_sampled{} 2)
      assert body =~ ~s(symphony_run_cpu_percent{backend="codex",issue="PAY-1",stage="implement"} 7.0)
      assert body =~ ~s(symphony_run_memory_bytes{backend="codex",issue="PAY-1",stage="implement"} 6144000)
      assert body =~ ~s(symphony_run_cpu_percent{backend="claude",issue="PAY-2",stage="review"} 4.0)
      refute body =~ "REMOTE-1"
    end

    test "does not run a command when nothing is running" do
      runner = fn _command, _args, _opts -> flunk("command should not run") end

      assert :ok =
               Sampler.sample(
                 settings: no_sandbox_settings(),
                 snapshot_fun: fn -> %{running: []} end,
                 command_runner: runner
               )

      assert Prometheus.render() =~ ~s(symphony_runs_sampled{} 0)
    end

    test "handles unavailable snapshots and empty container sets" do
      assert :ok =
               Sampler.sample(
                 settings: no_sandbox_settings(),
                 snapshot_fun: fn -> :unavailable end,
                 command_runner: fn _, _, _ -> flunk("command should not run") end
               )

      assert :ok =
               Sampler.sample(
                 settings: docker_settings("docker"),
                 snapshot_fun: fn -> %{"running" => [%{"identifier" => "PAY-1", "workspace_path" => nil}]} end,
                 command_runner: fn _, _, _ -> flunk("command should not run") end
               )

      assert :ok =
               Sampler.sample(
                 settings: no_sandbox_settings(),
                 snapshot_fun: fn -> [%{identifier: "PAY-1", agent_server_pid: "123", worker_host: nil}] end,
                 command_runner: fn "ps", _args, _opts -> {"PID PPID RSS %CPU\n", 0} end
               )
    end

    test "logs each distinct command or parse failure once and keeps sampling" do
      settings = docker_settings("podman")

      {:ok, pid} =
        start_supervised(
          {Sampler,
           name: :capacity_log_sampler,
           settings: settings,
           sample_interval_ms: 0,
           snapshot_fun: fn -> %{running: [%{identifier: "PAY-1", workspace_path: "/tmp/capacity-failure"}]} end,
           command_runner: fn _command, _args, _opts -> {"not json", 0} end}
        )

      log =
        capture_log(fn ->
          send(pid, :sample)
          :sys.get_state(pid)
          send(pid, :sample)
          :sys.get_state(pid)
          send(pid, :unexpected)
          :sys.get_state(pid)
        end)

      assert length(String.split(log, "Capacity sampler failed")) == 2
    end

    test "logs command failures and exceptions once and never crashes" do
      settings = docker_settings("podman")
      snapshot = fn -> %{running: [%{identifier: "PAY-1", workspace_path: "/tmp/capacity-failure"}]} end

      sampler_opts = [
        name: :capacity_log_sampler,
        settings: settings,
        sample_interval_ms: 0,
        snapshot_fun: snapshot,
        command_runner: fn _command, _args, _opts -> {"boom", 1} end
      ]

      {:ok, pid} = start_supervised({Sampler, sampler_opts})

      log =
        capture_log(fn ->
          send(pid, :sample)
          :sys.get_state(pid)
          send(pid, :sample)
          :sys.get_state(pid)
        end)

      assert length(String.split(log, "Capacity sampler failed")) == 2
      assert Process.alive?(pid)
    end

    test "logs a thrown command runner and an exception escaping sampling once" do
      snapshot = fn -> %{running: [%{identifier: "PAY-1", workspace_path: "/tmp/capacity-failure"}]} end

      throwing_opts = [
        name: :capacity_throwing_sampler,
        settings: docker_settings("podman"),
        sample_interval_ms: 0,
        snapshot_fun: snapshot,
        command_runner: fn _command, _args, _opts -> throw(:boom) end
      ]

      {:ok, throwing} =
        start_supervised(%{id: :capacity_throwing, start: {Sampler, :start_link, [throwing_opts]}})

      log =
        capture_log(fn ->
          send(throwing, :sample)
          :sys.get_state(throwing)
        end)

      assert log =~ "Capacity sampler failed"
      assert Process.alive?(throwing)

      bad_settings = %{capacity: %{sample_interval_ms: 0}, sandbox: %{kind: "docker", command: nil}}

      bad_opts = [
        name: :capacity_bad_sampler,
        settings: bad_settings,
        sample_interval_ms: 0,
        snapshot_fun: snapshot,
        command_runner: fn _, _, _ -> {"", 0} end
      ]

      {:ok, bad} =
        start_supervised(%{id: :capacity_bad, start: {Sampler, :start_link, [bad_opts]}})

      log =
        capture_log(fn ->
          send(bad, :sample)
          :sys.get_state(bad)
        end)

      assert log =~ "Capacity sampler failed"
      assert Process.alive?(bad)
    end

    test "handles snapshot exceptions and malformed snapshots" do
      assert :ok =
               Sampler.sample(
                 settings: no_sandbox_settings(),
                 snapshot_fun: fn -> throw(:boom) end,
                 command_runner: fn _, _, _ -> {"", 0} end
               )

      assert :ok =
               Sampler.sample(
                 settings: no_sandbox_settings(),
                 snapshot_fun: fn -> raise "boom" end,
                 command_runner: fn _, _, _ -> {"", 0} end
               )

      assert :ok =
               Sampler.sample(
                 settings: no_sandbox_settings(),
                 snapshot_fun: fn -> :timeout end,
                 command_runner: fn _, _, _ -> {"", 0} end
               )

      assert :ok =
               Sampler.sample(
                 settings: no_sandbox_settings(),
                 snapshot_fun: fn -> :weird end,
                 command_runner: fn _, _, _ -> {"", 0} end
               )
    end

    test "handles ps and container command failures without metrics" do
      snapshot = fn -> %{running: [%{identifier: "PAY-1", agent_server_pid: "100"}]} end

      assert :ok =
               Sampler.sample(
                 settings: no_sandbox_settings(),
                 snapshot_fun: snapshot,
                 command_runner: fn "ps", _, _ -> {"bad", 1} end
               )

      assert :ok =
               Sampler.sample(
                 settings: no_sandbox_settings(),
                 snapshot_fun: snapshot,
                 command_runner: fn "ps", _, _ -> {nil, 0} end
               )

      assert :ok =
               Sampler.sample(
                 settings: no_sandbox_settings(),
                 snapshot_fun: snapshot,
                 command_runner: fn "ps", _, _ -> raise "boom" end
               )

      assert :ok =
               Sampler.sample(
                 settings: docker_settings("docker"),
                 snapshot_fun: fn -> %{running: [%{identifier: "PAY-1", workspace_path: "/tmp/capacity-failure"}]} end,
                 command_runner: fn _, _, _ -> {nil, 1} end
               )
    end
  end

  defp docker_settings(command) do
    {:ok, settings} =
      Schema.parse(%{
        "sandbox" => %{"kind" => "docker", "image" => "symphony:test", "command" => command},
        "capacity" => %{"sample_interval_ms" => 0}
      })

    settings
  end

  defp no_sandbox_settings do
    {:ok, settings} = Schema.parse(%{"capacity" => %{"sample_interval_ms" => 0}})
    settings
  end
end
