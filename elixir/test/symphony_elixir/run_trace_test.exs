defmodule SymphonyElixir.RunTraceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunSpec
  alias SymphonyElixir.RunTrace
  alias SymphonyElixir.TraceExporter

  @issue %Issue{id: "issue-1", identifier: "MT-7", project_slug: "proj"}

  test "trace and root span ids are derived from the run id" do
    trace_id = RunTrace.trace_id("run-1")
    root_span_id = RunTrace.root_span_id("run-1")

    assert trace_id =~ ~r/^[0-9a-f]{32}$/
    assert root_span_id =~ ~r/^[0-9a-f]{16}$/
    assert RunTrace.trace_id("run-1") == trace_id
    assert RunTrace.root_span_id("run-1") == root_span_id
    refute RunTrace.trace_id("run-2") == trace_id
    refute String.starts_with?(trace_id, root_span_id)
    assert RunTrace.new_span_id() =~ ~r/^[0-9a-f]{16}$/
    refute RunTrace.new_span_id() == RunTrace.new_span_id()
  end

  test "the root context names the run and its traceparent round-trips" do
    root = RunTrace.root("run-1", attempt: 2, launcher: SymphonyElixir.RunLauncher.Kubernetes, issue: @issue, backend: "claude")

    assert root.trace_id == RunTrace.trace_id("run-1")
    assert root.span_id == RunTrace.root_span_id("run-1")
    assert root.parent_span_id == nil
    assert root.launcher == "kubernetes"
    assert {root.issue_id, root.identifier, root.project} == {"issue-1", "MT-7", "proj"}

    traceparent = RunTrace.traceparent(root)
    assert traceparent == "00-#{root.trace_id}-#{root.span_id}-01"
    assert RunTrace.parse_traceparent(traceparent) == {:ok, {root.trace_id, root.span_id}}
    assert RunTrace.parse_traceparent(String.upcase(traceparent) <> "-extra") == {:ok, {root.trace_id, root.span_id}}

    child = RunTrace.child(root)
    assert child.trace_id == root.trace_id
    assert child.parent_span_id == root.span_id
    refute child.span_id == root.span_id

    # An issue given as a plain map with string keys works too.
    assert RunTrace.root("run-1", issue: %{"identifier" => "MT-8"}).identifier == "MT-8"
  end

  test "parse_traceparent rejects malformed values" do
    trace_id = String.duplicate("a", 32)
    span_id = String.duplicate("b", 16)

    for value <- [
          nil,
          42,
          "",
          "00-#{trace_id}-#{span_id}",
          "ff-#{trace_id}-#{span_id}-01",
          "00-#{String.duplicate("0", 32)}-#{span_id}-01",
          "00-#{trace_id}-#{String.duplicate("0", 16)}-01",
          "00-#{String.slice(trace_id, 0, 31)}-#{span_id}-01",
          "00-#{trace_id}-#{span_id}-zz"
        ] do
      assert RunTrace.parse_traceparent(value) == :error, inspect(value)
    end
  end

  test "launcher names" do
    assert RunTrace.launcher_name(nil) == nil
    assert RunTrace.launcher_name("process") == "process"
    assert RunTrace.launcher_name(SymphonyElixir.RunLauncher.Local) == "local"
    assert RunTrace.launcher_name(SymphonyElixir.RunLauncher.Process) == "process"
    assert RunTrace.launcher_name(:erlang_module) == "erlang_module"
  end

  test "the spec map carries the root traceparent and the OTLP override, never credentials" do
    root = RunTrace.root("run-1", launcher: "kubernetes")

    assert RunTrace.to_spec_map(root) == %{
             "traceparent" => RunTrace.traceparent(root),
             "launcher" => "kubernetes",
             "started_on" => nil,
             "otlp_endpoint" => nil,
             "otlp_protocol" => nil
           }

    started = RunTrace.root("run-1", started_at: ~U[2026-10-22 07:30:00Z])
    assert RunTrace.to_spec_map(started)["started_on"] == "2026/10/22"

    map = RunTrace.to_spec_map(root, %{endpoint: "http://otel.test:4318", protocol: "http/protobuf"})
    assert map["otlp_endpoint"] == "http://otel.test:4318"
    assert RunTrace.spec_otlp_override(map) == %{endpoint: "http://otel.test:4318", protocol: "http/protobuf"}
    assert RunTrace.spec_otlp_override(%{"otlp_endpoint" => "http://otel.test:4318"}).protocol == "http/protobuf"
    assert RunTrace.spec_otlp_override(%{"otlp_endpoint" => ""}) == nil
    assert RunTrace.spec_otlp_override(nil) == nil
  end

  test "from_spec continues the spec's traceparent, or derives it from the run id" do
    upstream = "00-#{String.duplicate("c", 32)}-#{String.duplicate("d", 16)}-01"

    spec = %RunSpec{
      run_id: "run-9",
      epoch: 1,
      attempt: 3,
      issue: @issue,
      backend: "codex",
      telemetry: %{"traceparent" => upstream, "launcher" => "process", "started_on" => "2026/10/21"}
    }

    context = RunTrace.from_spec(spec)
    assert {context.trace_id, context.span_id} == {String.duplicate("c", 32), String.duplicate("d", 16)}
    assert {context.run_id, context.attempt, context.launcher, context.backend} == {"run-9", 3, "process", "codex"}
    assert context.started_on == "2026/10/21"

    # Only a YYYY/MM/DD date is taken from a spec.
    for bad <- ["2026-10-21", "../x", 20_261_021] do
      assert RunTrace.from_spec(%{spec | telemetry: %{spec.telemetry | "started_on" => bad}}).started_on == nil
    end

    # An older spec (no telemetry) or a bad traceparent gets the derived root.
    for telemetry <- [nil, %{"traceparent" => "garbage"}] do
      context = RunTrace.from_spec(%{spec | telemetry: telemetry})
      assert context.trace_id == RunTrace.trace_id("run-9")
      assert context.span_id == RunTrace.root_span_id("run-9")
    end
  end

  test "the current context is per process" do
    root = RunTrace.root("run-1")
    assert RunTrace.current() == nil
    assert :ok = RunTrace.put_current(root)
    assert RunTrace.current() == root
    assert Task.async(fn -> RunTrace.current() end) |> Task.await() == nil
    assert :ok = RunTrace.put_current(nil)
    assert RunTrace.current() == nil
  end

  test "started_on is the start's UTC date, so either side of midnight differs" do
    {:ok, after_midnight} = DateTime.new(~D[2026-10-23], ~T[00:30:00], "Etc/UTC")
    assert RunTrace.started_on(after_midnight) == "2026/10/23"
    assert RunTrace.started_on(DateTime.add(after_midnight, -3600)) == "2026/10/22"
    assert RunTrace.started_on(nil) == nil
  end

  test "resource attributes name the run and leave out what is unknown" do
    assert RunTrace.resource_attributes(nil) == %{}

    root = RunTrace.root("run-1", attempt: 0, launcher: "local", started_at: ~U[2026-01-05 23:59:59Z], issue: @issue, backend: "claude")

    assert RunTrace.resource_attributes(root) == %{
             "symphony.run.id" => "run-1",
             "symphony.run.attempt" => "0",
             "symphony.run.launcher" => "local",
             "symphony.run.started_on" => "2026/01/05",
             "symphony.project" => "proj",
             "symphony.trace_id" => root.trace_id,
             "linear.issue.id" => "issue-1",
             "linear.issue.identifier" => "MT-7",
             "symphony.backend" => "claude"
           }

    assert RunTrace.resource_attributes(RunTrace.root("run-1", issue: %{identifier: ""})) == %{
             "symphony.run.id" => "run-1",
             "symphony.trace_id" => RunTrace.trace_id("run-1")
           }
  end

  describe "emit/5" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(),
        telemetry_enabled: true,
        telemetry_otlp_endpoint: "http://collector.test:4318",
        telemetry_otlp_protocol: "http/protobuf"
      )

      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:export, Jason.decode!(body)})
        Plug.Conn.send_resp(conn, 200, "{}")
      end

      name = :"run_trace_exporter_#{System.unique_integer([:positive])}"
      start_supervised!({TraceExporter, name: name, interval_ms: 60_000, req_options: [plug: plug]})
      %{exporter: name}
    end

    test "a nil context emits nothing" do
      assert RunTrace.emit(nil, "symphony.run", DateTime.utc_now()) == :ok
    end

    test "the root span gets the Langfuse trace name and session", %{exporter: exporter} do
      root = RunTrace.root("run-1", attempt: 2, issue: @issue)
      started_at = DateTime.add(DateTime.utc_now(), -5, :second)

      with_exporter(exporter, fn ->
        assert RunTrace.emit(root, "symphony.run", started_at, {:error, "boom"}, %{"symphony.run.outcome" => "crashed"}) == :ok
        # A span that cannot be built (a bad start) is dropped, not raised.
        assert RunTrace.emit(root, "symphony.run", "not a time") == :ok
        # Without an attempt or identifier the name says so.
        assert RunTrace.emit(RunTrace.root("run-2"), "symphony.run", started_at) == :ok
        # Other spans get only their own attributes; a start may be in nanoseconds.
        assert RunTrace.emit(RunTrace.child(root), "symphony.agent_run", 1_000, :ok, %{"k" => "v"}) == :ok
      end)

      TraceExporter.flush(5_000, exporter)
      assert_receive {:export, %{"resourceSpans" => resource_spans}}
      spans = for rs <- resource_spans, ss <- rs["scopeSpans"], span <- ss["spans"], do: span
      {[child], spans} = Enum.split_with(spans, &(&1["name"] == "symphony.agent_run"))
      assert child["parentSpanId"] == root.span_id
      assert child["startTimeUnixNano"] == "1000"
      assert child["attributes"] == [%{"key" => "k", "value" => %{"stringValue" => "v"}}]
      assert [run_1, run_2] = Enum.sort_by(spans, &(&1["traceId"] != root.trace_id))

      attributes = Map.new(run_1["attributes"], &{&1["key"], &1["value"]["stringValue"]})
      assert attributes["langfuse.trace.name"] == "symphony.run MT-7 attempt 2"
      assert attributes["langfuse.session.id"] == "MT-7"
      assert attributes["session.id"] == "MT-7"
      assert attributes["symphony.run.outcome"] == "crashed"
      assert run_1["status"] == %{"code" => 2, "message" => "boom"}
      refute Map.has_key?(run_1, "parentSpanId")

      assert Enum.find(run_2["attributes"], &(&1["key"] == "langfuse.trace.name"))["value"]["stringValue"] == "symphony.run unknown"
    end
  end

  # RunTrace emits to the default exporter name; the test's exporter stands in.
  defp with_exporter(name, fun) do
    term = :persistent_term.get({TraceExporter, name})
    previous = :persistent_term.get({TraceExporter, TraceExporter}, nil)
    :persistent_term.put({TraceExporter, TraceExporter}, term)

    try do
      fun.()
    after
      if previous,
        do: :persistent_term.put({TraceExporter, TraceExporter}, previous),
        else: :persistent_term.erase({TraceExporter, TraceExporter})
    end
  end
end
