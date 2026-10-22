defmodule SymphonyElixir.RunTracePropagationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunnerTestSupport, as: Support
  alias SymphonyElixir.{RunRegistry, RunSpec, RunToken, RunTrace, Telemetry, TraceExporter}

  @collector "http://collector.test:4318"
  @pod_collector "http://otel-collector.symphony.svc:4318"

  # A process launcher (it gets the spec) that names a pod collector, like the
  # Kubernetes one, and whose run ends when the test says so.
  defmodule TraceLauncher do
    def start_process(spec, _opts) do
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      send(:persistent_term.get({__MODULE__, :recipient}), {:trace_start, spec, pid})
      {:ok, pid, "trace:" <> spec.run_id}
    end

    def alive?(_ref), do: true
    def stop(_ref), do: :ok
    def otlp_override(_settings), do: %{endpoint: "http://otel-collector.symphony.svc:4318", protocol: "http/protobuf"}
  end

  defmodule FailingLauncher do
    def start_process(_spec, _opts), do: {:error, :no_capacity}
    def alive?(_ref), do: false
    def stop(_ref), do: :ok
  end

  setup do
    root = Support.temp_root!("run-trace")
    Support.setup_runs!(root)
    test_pid = self()

    keys = [:state_root, :run_launcher, :trace_exporter_req_options]
    previous = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1)})
    Application.put_env(:symphony_elixir, :state_root, Path.join(root, "state"))

    Application.put_env(:symphony_elixir, :trace_exporter_req_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:spans, conn.host, Jason.decode!(body)})
        Plug.Conn.send_resp(conn, 200, "{}")
      end
    )

    :persistent_term.put({TraceLauncher, :recipient}, test_pid)

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:symphony_elixir, key, value),
          else: Application.delete_env(:symphony_elixir, key)
      end

      :persistent_term.erase({TraceLauncher, :recipient})
      Telemetry.put_otlp_override(nil)
    end)

    write_traced_workflow!(root)
    # Spans left from earlier tests are not this test's.
    TraceExporter.flush()
    drain_spans()

    %{root: root}
  end

  test "process dispatch puts the run's trace context and pod collector in the spec, and the trace ends with the run" do
    issue = Support.issue_fixture("issue-trace", "MT-TRACE")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :run_launcher, TraceLauncher)

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "DispatchOrchestrator"))

    assert_receive {:trace_start, %RunSpec{run_id: run_id, telemetry: telemetry}, run_pid}, 5_000
    root = RunTrace.root(run_id)
    started_on = telemetry["started_on"]
    assert started_on =~ ~r|^\d{4}/\d{2}/\d{2}$|

    assert telemetry == %{
             "traceparent" => RunTrace.traceparent(root),
             "launcher" => "trace_launcher",
             "started_on" => started_on,
             "otlp_endpoint" => @pod_collector,
             "otlp_protocol" => "http/protobuf"
           }

    # Stopped once the orchestrator monitors it, so the run ends normally.
    assert eventually(fn -> match?(%{pid: ^run_pid}, :sys.get_state(pid).running[issue.id]) end)
    send(run_pid, :stop)
    assert eventually(fn -> not Map.has_key?(:sys.get_state(pid).running, issue.id) end)
    GenServer.stop(pid)

    spans = collect_spans(root.trace_id)
    assert %{"symphony.dispatch" => dispatch, "symphony.run" => run} = Map.new(spans, &{&1["name"], &1})

    assert dispatch["parentSpanId"] == root.span_id
    assert dispatch["status"] == %{"code" => 1}
    assert run["spanId"] == root.span_id
    refute Map.has_key?(run, "parentSpanId")
    assert run["status"] == %{"code" => 1}
    assert attribute(run, "symphony.run.outcome") == "finished"
    assert attribute(run, "langfuse.trace.name") == "symphony.run MT-TRACE attempt 0"
    assert run["resource"]["symphony.run.id"] == run_id
    assert run["resource"]["symphony.run.launcher"] == "trace_launcher"
    assert run["resource"]["symphony.run.started_on"] == started_on
    assert dispatch["resource"]["symphony.run.started_on"] == started_on
    assert run["resource"]["linear.issue.identifier"] == "MT-TRACE"
    assert run["resource"]["service.name"] == "symphony"
  end

  test "a dispatch the launcher refuses is an error span" do
    issue = Support.issue_fixture("issue-refused-trace", "MT-REFUSED")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :run_launcher, FailingLauncher)

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "RefusedOrchestrator"))
    assert eventually(fn -> Map.has_key?(:sys.get_state(pid).retry_attempts, issue.id) end)
    GenServer.stop(pid)

    TraceExporter.flush()
    assert dispatch = Enum.find(drain_spans(), &(&1["name"] == "symphony.dispatch"))
    assert dispatch["status"] == %{"code" => 2, "message" => "failed to spawn agent: :no_capacity"}
  end

  test "an adopted run keeps its trace: the root span comes from the registry's run id and start", %{root: root} do
    issue = Support.issue_fixture("issue-adopt-trace", "MT-ADOPT-TRACE")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    run_id = "run-adopt-trace"
    # Started on an earlier day: the date comes from the registry, not now.
    started_at_ms = DateTime.to_unix(~U[2026-01-02 23:00:00Z], :millisecond)

    :ok =
      RunRegistry.record(issue.id, %{
        run_id: run_id,
        attempt: 3,
        epoch: 2,
        launcher: TraceLauncher,
        ref: "trace:" <> run_id,
        started_at_unix_ms: started_at_ms,
        metadata: %{identifier: issue.identifier, issue: issue, backend: "claude", workspace_path: Path.join(root, "w")}
      })

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "AdoptOrchestrator"))
    assert %{run_id: ^run_id} = :sys.get_state(pid).running[issue.id]

    send(pid, {:run_finished, issue.id, run_id, "normal"})
    assert eventually(fn -> not Map.has_key?(:sys.get_state(pid).running, issue.id) end)
    GenServer.stop(pid)

    assert [run] = collect_spans(RunTrace.trace_id(run_id))
    assert run["name"] == "symphony.run"
    assert run["spanId"] == RunTrace.root_span_id(run_id)
    assert run["startTimeUnixNano"] == Integer.to_string(started_at_ms * 1_000_000)
    assert run["resource"]["symphony.run.attempt"] == "3"
    assert run["resource"]["symphony.run.started_on"] == "2026/01/02"
  end

  test "a run recovered as already finished still closes its trace", %{root: root} do
    issue = Support.issue_fixture("issue-recovered-trace", "MT-RECOVERED")
    run_id = "run-recovered-trace"

    :ok =
      RunRegistry.record(issue.id, %{
        run_id: run_id,
        attempt: 0,
        epoch: 1,
        launcher: TraceLauncher,
        ref: "trace:" <> run_id,
        started_at_unix_ms: System.system_time(:millisecond),
        finished: "agent crashed",
        metadata: %{identifier: issue.identifier, issue: issue, workspace_path: Path.join(root, "w")}
      })

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "RecoveredOrchestrator"))
    GenServer.stop(pid)

    assert [run] = collect_spans(RunTrace.trace_id(run_id))
    assert run["status"] == %{"code" => 2, "message" => "agent crashed"}
    assert attribute(run, "symphony.run.outcome") == "crashed"
  end

  test "a local run is traced in-process: its agent_run span is a child of the run", %{root: root} do
    issue = Support.issue_fixture("issue-local-trace", "MT-LOCAL-TRACE")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :run_launcher, SymphonyElixir.RunLauncher.Local)
    write_traced_workflow!(root, hook_before_run: "exit 7")

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, "LocalOrchestrator"))
    assert eventually(fn -> Map.has_key?(:sys.get_state(pid).retry_attempts, issue.id) end, 250)
    GenServer.stop(pid)

    TraceExporter.flush()
    spans = drain_spans()
    agent_run = Enum.find(spans, &(&1["name"] == "symphony.agent_run"))
    assert agent_run, inspect(Enum.map(spans, & &1["name"]))
    trace_id = agent_run["traceId"]

    by_name = Map.new(Enum.filter(spans, &(&1["traceId"] == trace_id)), &{&1["name"], &1})
    run = by_name["symphony.run"]
    assert agent_run["parentSpanId"] == run["spanId"]
    assert by_name["symphony.dispatch"]["parentSpanId"] == run["spanId"]
    assert agent_run["status"]["code"] == 2
    assert run["status"]["code"] == 2
    assert attribute(run, "symphony.run.outcome") == "crashed"
    assert run["resource"]["symphony.run.launcher"] == "local"
    assert trace_id == RunTrace.trace_id(run["resource"]["symphony.run.id"])
  end

  test "the runner continues the spec's trace, gives the agent TRACEPARENT and exports to the pod collector", %{root: root} do
    endpoint = Support.start_endpoint!()
    issue = Support.issue_fixture("issue-runner-trace", "MT-RUNNER-TRACE")
    run_id = "run-runner-trace"
    env_file = Path.join(root, "agent.env")

    write_traced_workflow!(root, claude_command: fake_claude!(root, env_file), max_turns: 1)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    record = Support.record_run!(issue.id, run_id, identifier: issue.identifier, backend: "claude", epoch: 1)

    root_context = RunTrace.root(run_id, launcher: "kubernetes")

    spec = %RunSpec{
      run_id: run_id,
      epoch: record.epoch,
      attempt: 0,
      issue: issue,
      backend: "claude",
      controller_url: endpoint.url,
      token: RunToken.sign(run_id, record.epoch),
      telemetry: RunTrace.to_spec_map(root_context, %{endpoint: @pod_collector, protocol: "http/json"})
    }

    assert {:ok, spec_path} = RunSpec.write(spec)
    assert :ok = SymphonyElixir.Runner.run(spec_path)
    # The override is the runner's alone; it is gone once the run is.
    assert Telemetry.otlp_override() == nil

    agent_env =
      env_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(&List.to_tuple(String.split(&1, "=", parts: 2)))

    assert {:ok, {trace_id, agent_parent}} = RunTrace.parse_traceparent(agent_env["TRACEPARENT"])
    assert trace_id == root_context.trace_id
    assert agent_env["OTEL_EXPORTER_OTLP_ENDPOINT"] == @pod_collector
    assert agent_env["OTEL_EXPORTER_OTLP_PROTOCOL"] == "http/json"
    assert agent_env["OTEL_RESOURCE_ATTRIBUTES"] =~ "symphony.run.id=run-runner-trace"
    assert agent_env["OTEL_RESOURCE_ATTRIBUTES"] =~ "symphony.run.launcher=kubernetes"

    assert_receive {:spans, "otel-collector.symphony.svc", body}, 5_000
    assert [agent_run] = spans_of(body, trace_id)
    assert agent_run["name"] == "symphony.agent_run"
    assert agent_run["spanId"] == agent_parent
    assert agent_run["parentSpanId"] == root_context.span_id
    assert agent_run["status"] == %{"code" => 1}
    assert agent_run["resource"]["symphony.component"] == "runner"
    SymphonyElixir.RunnerCommands.reset()
  end

  defp write_traced_workflow!(root, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "memory",
          agent_backend: "claude",
          workspace_root: Path.join(root, "workspaces"),
          telemetry_enabled: true,
          telemetry_otlp_endpoint: @collector,
          telemetry_otlp_protocol: "http/protobuf"
        ],
        overrides
      )
    )
  end

  # A Claude stand-in that records its trace and OTLP environment, then
  # answers each prompt with one successful turn.
  defp fake_claude!(root, env_file) do
    path = Path.join(root, "fake-claude-env.sh")

    File.write!(path, """
    #!/bin/sh
    env | grep -E '^(TRACEPARENT|OTEL_)' > '#{env_file}'
    session_id=""
    previous_arg=""
    for arg in "$@"; do
      if [ "$previous_arg" = "--session-id" ]; then session_id="$arg"; fi
      previous_arg="$arg"
    done
    while IFS= read -r line; do
      printf '%s\\n' "{\\"type\\":\\"system\\",\\"subtype\\":\\"init\\",\\"session_id\\":\\"$session_id\\"}"
      printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"session_id\\":\\"$session_id\\",\\"uuid\\":\\"trace-result\\"}"
    done
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp collect_spans(trace_id) do
    TraceExporter.flush()
    drain_spans() |> Enum.filter(&(&1["traceId"] == trace_id))
  end

  defp drain_spans(acc \\ []) do
    receive do
      {:spans, _host, body} -> drain_spans(acc ++ spans_of(body, nil))
    after
      100 -> acc
    end
  end

  # Spans with their resource attributes folded in as "resource".
  defp spans_of(body, trace_id) do
    for resource_spans <- body["resourceSpans"],
        resource = Map.new(resource_spans["resource"]["attributes"], &{&1["key"], &1["value"]["stringValue"]}),
        scope <- resource_spans["scopeSpans"],
        span <- scope["spans"],
        is_nil(trace_id) or span["traceId"] == trace_id,
        do: Map.put(span, "resource", resource)
  end

  defp attribute(span, key) do
    Enum.find_value(span["attributes"], fn attribute -> attribute["key"] == key && attribute["value"]["stringValue"] end)
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
