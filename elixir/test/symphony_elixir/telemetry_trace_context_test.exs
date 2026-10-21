defmodule SymphonyElixir.TelemetryTraceContextTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunTrace
  alias SymphonyElixir.Telemetry

  @issue %Issue{id: "issue-1", identifier: "MT-7", project_slug: "proj"}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      telemetry_enabled: true,
      telemetry_otlp_endpoint: "http://host.containers.internal:4318",
      telemetry_otlp_protocol: "http/protobuf",
      telemetry_otlp_logs_endpoint: "http://logs.test:4318/v1/logs",
      telemetry_otlp_logs_protocol: "http/json"
    )

    on_exit(fn ->
      Telemetry.put_otlp_override(nil)
      RunTrace.put_current(nil)
    end)

    root = RunTrace.root("run-1", attempt: 1, launcher: "kubernetes", issue: @issue, backend: "claude")
    %{root: root}
  end

  defp attributes(env) do
    env
    |> Map.new()
    |> Map.fetch!("OTEL_RESOURCE_ATTRIBUTES")
    |> String.split(",")
    |> Map.new(fn pair ->
      [key, value] = String.split(pair, "=", parts: 2)
      {URI.decode(key), URI.decode(value)}
    end)
  end

  test "without a run context agents get no TRACEPARENT and no run attributes" do
    for backend <- ["claude", "codex", "opencode"] do
      env = Telemetry.env_pairs(backend, @issue)
      refute List.keymember?(env, "TRACEPARENT", 0)
      refute Map.has_key?(attributes(env), "symphony.run.id")
    end
  end

  test "every backend's agent continues the current run context", %{root: root} do
    span = RunTrace.child(root)
    RunTrace.put_current(span)

    for backend <- ["claude", "codex", "opencode"] do
      env = Telemetry.env_pairs(backend, @issue)
      assert {"TRACEPARENT", RunTrace.traceparent(span)} in env

      attributes = attributes(env)
      assert attributes["symphony.run.id"] == "run-1"
      assert attributes["symphony.run.attempt"] == "1"
      assert attributes["symphony.run.launcher"] == "kubernetes"
      assert attributes["symphony.project"] == "proj"
      assert attributes["symphony.trace_id"] == root.trace_id
      assert attributes["linear.issue.identifier"] == "MT-7"
      # The backend actually started wins over the one the run was routed to.
      assert attributes["symphony.backend"] == backend
    end
  end

  test "an OTLP override replaces the shared and per-signal endpoints" do
    configured = Map.new(Telemetry.env_pairs("claude", @issue))
    assert configured["OTEL_EXPORTER_OTLP_ENDPOINT"] == "http://host.containers.internal:4318"
    assert configured["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"] == "http://logs.test:4318/v1/logs"

    Telemetry.put_otlp_override(%{endpoint: "http://otel-collector.symphony.svc:4318", protocol: "http/protobuf"})
    assert Telemetry.otlp_override() == %{endpoint: "http://otel-collector.symphony.svc:4318", protocol: "http/protobuf"}

    env = Map.new(Telemetry.env_pairs("claude", @issue))
    assert env["OTEL_EXPORTER_OTLP_ENDPOINT"] == "http://otel-collector.symphony.svc:4318"
    assert env["OTEL_EXPORTER_OTLP_PROTOCOL"] == "http/protobuf"
    refute Map.has_key?(env, "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")
    refute Map.has_key?(env, "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL")
    refute Enum.any?(Map.keys(env), &String.contains?(&1, "HEADERS"))

    assert Telemetry.codex_config_overrides(@issue) |> Enum.take(3) == [
             ~s(otel.exporter={ otlp-http = { endpoint = "http://otel-collector.symphony.svc:4318/v1/logs", protocol = "binary" } }),
             ~s(otel.trace_exporter={ otlp-http = { endpoint = "http://otel-collector.symphony.svc:4318/v1/traces", protocol = "binary" } }),
             ~s(otel.metrics_exporter={ otlp-http = { endpoint = "http://otel-collector.symphony.svc:4318/v1/metrics", protocol = "binary" } })
           ]

    Telemetry.put_otlp_override(%{endpoint: "http://otel-collector.symphony.svc:4317", protocol: "grpc"})
    assert hd(Telemetry.codex_config_overrides(@issue)) == ~s(otel.exporter={ otlp-grpc = { endpoint = "http://otel-collector.symphony.svc:4317" } })

    Telemetry.put_otlp_override(nil)
    assert Telemetry.otlp_override() == nil
    Application.put_env(:symphony_elixir, :telemetry_otlp_override, %{endpoint: nil})
    assert Telemetry.otlp_override() == nil
  end

  test "telemetry off means no trace context either", %{root: root} do
    RunTrace.put_current(root)
    write_workflow_file!(Workflow.workflow_file_path(), telemetry_enabled: false)

    assert Telemetry.env_pairs("claude", @issue) == []
    assert Telemetry.env_pairs("codex", @issue) == []
  end
end
