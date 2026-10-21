defmodule SymphonyElixir.TraceExporterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Telemetry
  alias SymphonyElixir.TraceExporter

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      telemetry_enabled: true,
      telemetry_otlp_endpoint: "http://collector.test:4318/",
      telemetry_otlp_protocol: "http/protobuf",
      telemetry_resource_attributes: %{"environment" => "test"}
    )

    on_exit(fn -> Telemetry.put_otlp_override(nil) end)
    :ok
  end

  defp start_exporter(opts \\ []) do
    test_pid = self()
    status = Keyword.get(opts, :status, 200)

    plug =
      Keyword.get(opts, :plug, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:export, conn.request_path, conn.host, Jason.decode!(body)})
        Plug.Conn.send_resp(conn, status, "{}")
      end)

    name = :"trace_exporter_#{System.unique_integer([:positive])}"
    defaults = [name: name, interval_ms: 60_000, req_options: [plug: plug]]
    start_supervised!(Supervisor.child_spec({TraceExporter, Keyword.merge(defaults, Keyword.drop(opts, [:status, :plug]))}, id: name))
    name
  end

  defp span(overrides \\ %{}) do
    Map.merge(
      %{
        trace_id: String.duplicate("a", 32),
        span_id: String.duplicate("b", 16),
        parent_span_id: String.duplicate("c", 16),
        name: "symphony.agent_run",
        start_ns: 1_000,
        end_ns: 2_000,
        status: :ok,
        attributes: %{"flag" => true, "count" => 3, "ratio" => 0.5, "text" => "x", "skipped" => nil},
        resource: %{"symphony.run.id" => "run-1"}
      },
      overrides
    )
  end

  test "flush posts the queued spans as OTLP/JSON, grouped by resource" do
    exporter = start_exporter()

    TraceExporter.emit(span(), exporter)
    TraceExporter.emit(span(%{span_id: String.duplicate("d", 16), resource: %{"symphony.run.id" => "run-2"}}), exporter)
    TraceExporter.emit(span(%{span_id: String.duplicate("e", 16), parent_span_id: nil, end_ns: 10, status: {:error, "bad"}}), exporter)
    assert TraceExporter.stats(exporter).queued == 3

    assert TraceExporter.flush(5_000, exporter) == :ok
    assert_receive {:export, "/v1/traces", "collector.test", %{"resourceSpans" => resource_spans}}
    assert length(resource_spans) == 2

    run_1 = Enum.find(resource_spans, fn rs -> %{"key" => "symphony.run.id", "value" => %{"stringValue" => "run-1"}} in rs["resource"]["attributes"] end)
    resource = Map.new(run_1["resource"]["attributes"], &{&1["key"], &1["value"]["stringValue"]})
    assert resource["service.name"] == "symphony"
    assert resource["symphony.component"] == "controller"
    assert resource["environment"] == "test"

    assert [%{"scope" => %{"name" => "symphony"}, "spans" => [ok_span, error_span]}] = run_1["scopeSpans"]
    assert ok_span["traceId"] == String.duplicate("a", 32)
    assert ok_span["parentSpanId"] == String.duplicate("c", 16)
    assert ok_span["kind"] == 1
    assert ok_span["startTimeUnixNano"] == "1000"
    assert ok_span["endTimeUnixNano"] == "2000"
    assert ok_span["status"] == %{"code" => 1}

    assert ok_span["attributes"] == [
             %{"key" => "count", "value" => %{"intValue" => "3"}},
             %{"key" => "flag", "value" => %{"boolValue" => true}},
             %{"key" => "ratio", "value" => %{"doubleValue" => 0.5}},
             %{"key" => "text", "value" => %{"stringValue" => "x"}}
           ]

    refute Map.has_key?(error_span, "parentSpanId")
    # An end before the start is clamped to the start.
    assert error_span["endTimeUnixNano"] == "1000"
    assert error_span["status"] == %{"code" => 2, "message" => "bad"}

    assert %{queued: 0, exported: 3, dropped: 0, failed_batches: 0} = TraceExporter.stats(exporter)
    # Nothing queued: nothing posted.
    TraceExporter.flush(5_000, exporter)
    refute_receive {:export, _path, _host, _body}, 50
  end

  test "emit never raises, even for an exporter whose table is gone" do
    exporter = start_exporter()
    term = :persistent_term.get({TraceExporter, exporter})
    stop_supervised!(exporter)
    :persistent_term.put({TraceExporter, :stale_exporter}, term)

    try do
      assert TraceExporter.emit(span(), :stale_exporter) == :ok
    after
      :persistent_term.erase({TraceExporter, :stale_exporter})
    end

    # The default exporter (the application's) answers too.
    assert %{queued: _, dropped: _} = TraceExporter.stats()
  end

  test "a full queue drops new spans instead of growing" do
    exporter = start_exporter(max_queue_size: 2)

    for _ <- 1..5, do: TraceExporter.emit(span(), exporter)

    assert %{queued: 2, dropped: 3} = TraceExporter.stats(exporter)
  end

  test "large queues go out in batches" do
    exporter = start_exporter(max_batch_size: 2)

    for _ <- 1..5, do: TraceExporter.emit(span(), exporter)
    TraceExporter.flush(5_000, exporter)

    batches =
      for _ <- 1..3 do
        assert_receive {:export, _path, _host, %{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => spans}]}]}}
        length(spans)
      end

    assert batches == [2, 2, 1]
    assert TraceExporter.stats(exporter).exported == 5
  end

  test "spans are exported on the interval and when the exporter stops" do
    exporter = start_exporter(interval_ms: 20)
    TraceExporter.emit(span(), exporter)
    assert_receive {:export, _path, _host, _body}, 1_000

    TraceExporter.emit(span(), exporter)
    send(exporter, :unrelated)
    stop_supervised!(exporter)
    assert_receive {:export, _path, _host, _body}, 1_000
    # A stopped exporter takes nothing and reports nothing.
    assert TraceExporter.emit(span(), exporter) == :ok
    assert TraceExporter.stats(exporter) == %{queued: 0, dropped: 0, exported: 0, failed_batches: 0}
    assert TraceExporter.flush(100, exporter) == :ok
  end

  test "a rejected or failed export drops its batch and counts it" do
    exporter = start_exporter(status: 503)
    TraceExporter.emit(span(), exporter)
    TraceExporter.flush(5_000, exporter)
    assert_receive {:export, _path, _host, _body}
    assert %{failed_batches: 1, dropped: 1, exported: 0, queued: 0} = TraceExporter.stats(exporter)

    raising = start_exporter(plug: fn _conn -> raise "collector exploded" end)
    TraceExporter.emit(span(), raising)
    TraceExporter.flush(5_000, raising)
    assert %{failed_batches: 1, dropped: 1} = TraceExporter.stats(raising)
  end

  test "nothing is queued while export is off" do
    exporter = start_exporter()
    write_workflow_file!(Workflow.workflow_file_path(), telemetry_enabled: false)
    TraceExporter.emit(span(), exporter)
    assert TraceExporter.stats(exporter).queued == 0

    # Settings that fail to load turn export off too.
    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "")
    TraceExporter.emit(span(), exporter)
    assert TraceExporter.stats(exporter).queued == 0
  end

  test "a gRPC-only config drops Symphony's spans and warns once" do
    exporter = start_exporter()

    write_workflow_file!(Workflow.workflow_file_path(),
      telemetry_enabled: true,
      telemetry_otlp_endpoint: "http://collector.test:4317",
      telemetry_otlp_protocol: "grpc"
    )

    log =
      capture_log(fn ->
        TraceExporter.emit(span(), exporter)
        TraceExporter.flush(5_000, exporter)
        TraceExporter.emit(span(), exporter)
        TraceExporter.flush(5_000, exporter)
      end)

    assert length(String.split(log, "Symphony spans are not exported")) == 2
    assert %{dropped: 2, exported: 0} = TraceExporter.stats(exporter)
    refute_receive {:export, _path, _host, _body}, 50
  end

  test "spans queued while on are dropped when export is turned off before the flush" do
    exporter = start_exporter()
    TraceExporter.emit(span(), exporter)
    write_workflow_file!(Workflow.workflow_file_path(), telemetry_enabled: false)

    log = capture_log(fn -> TraceExporter.flush(5_000, exporter) end)

    refute log =~ "not exported"
    assert %{dropped: 1, queued: 0} = TraceExporter.stats(exporter)
  end

  test "the runner's OTLP override is where its spans go" do
    Telemetry.put_otlp_override(%{endpoint: "http://otel.symphony.svc:4318", protocol: "http/json"})
    Application.put_env(:symphony_elixir, :app_mode, :runner)
    exporter = start_exporter()

    TraceExporter.emit(span(), exporter)
    TraceExporter.flush(5_000, exporter)

    assert_receive {:export, "/v1/traces", "otel.symphony.svc", %{"resourceSpans" => [resource_spans]}}
    assert %{"key" => "symphony.component", "value" => %{"stringValue" => "runner"}} in resource_spans["resource"]["attributes"]
  end

  describe "traces_endpoint/0" do
    test "uses the traces endpoint as given, or the shared one plus /v1/traces" do
      assert TraceExporter.traces_endpoint() == "http://collector.test:4318/v1/traces"

      write_workflow_file!(Workflow.workflow_file_path(),
        telemetry_enabled: true,
        telemetry_otlp_endpoint: "http://collector.test:4317",
        telemetry_otlp_protocol: "grpc",
        telemetry_otlp_traces_endpoint: "http://traces.test:4318/custom",
        telemetry_otlp_traces_protocol: "http/json"
      )

      assert TraceExporter.traces_endpoint() == "http://traces.test:4318/custom"

      # A blank traces endpoint falls back to the shared one.
      write_workflow_file!(Workflow.workflow_file_path(),
        telemetry_enabled: true,
        telemetry_otlp_endpoint: "http://collector.test:4318",
        telemetry_otlp_protocol: "http/protobuf",
        telemetry_otlp_traces_endpoint: " "
      )

      assert TraceExporter.traces_endpoint() == "http://collector.test:4318/v1/traces"

      write_workflow_file!(Workflow.workflow_file_path(), codex_command: "")
      assert TraceExporter.traces_endpoint() == nil
    end

    test "is nil for gRPC, without an endpoint, and for a gRPC override" do
      write_workflow_file!(Workflow.workflow_file_path(), telemetry_enabled: true, telemetry_otlp_endpoint: "http://collector.test:4317", telemetry_otlp_protocol: "grpc")
      assert TraceExporter.traces_endpoint() == nil

      write_workflow_file!(Workflow.workflow_file_path(), telemetry_enabled: true, telemetry_otlp_endpoint: nil)
      assert TraceExporter.traces_endpoint() == nil

      Telemetry.put_otlp_override(%{endpoint: "http://otel.test:4317", protocol: "grpc"})
      assert TraceExporter.traces_endpoint() == nil
    end
  end

  test "limits come from the telemetry settings, with defaults when they cannot load" do
    exporter = start_exporter()
    assert %{max_queue_size: 2048, max_batch_size: 512, timeout_ms: 5_000} = :sys.get_state(exporter)

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "")
    fallback = start_exporter()
    assert %{max_queue_size: 2048, max_batch_size: 512, interval_ms: 60_000} = :sys.get_state(fallback)
  end
end
