defmodule SymphonyElixir.Telemetry do
  @moduledoc """
  Builds OpenTelemetry environment variable pairs for agent backend sessions.

  Invoked from each backend's `app_server` when preparing the subprocess
  environment. Returns an empty list when telemetry is disabled or when no
  issue context is available.
  """

  alias SymphonyElixir.Config

  @type backend :: String.t()
  @type env_pair :: {String.t(), String.t()}

  @spec env_pairs(backend(), map() | nil, map() | nil) :: [env_pair()]
  def env_pairs(backend, issue, account \\ nil)

  def env_pairs(_backend, nil, _account), do: []

  def env_pairs(backend, issue, account) when is_binary(backend) and is_map(issue) do
    if Config.telemetry_enabled?() do
      settings = Config.settings!()
      endpoint = Config.telemetry_otlp_endpoint()
      protocol = Config.telemetry_otlp_protocol()
      resource_attrs = Config.telemetry_issue_resource_attributes(issue, backend, account)
      include_traces = settings.telemetry.include_traces

      []
      |> put_backend_vars(backend, include_traces)
      |> maybe_put("OTEL_METRICS_EXPORTER", settings.telemetry.include_metrics && "otlp")
      |> maybe_put("OTEL_LOGS_EXPORTER", settings.telemetry.include_logs && "otlp")
      |> maybe_put("OTEL_TRACES_EXPORTER", include_traces && "otlp")
      |> maybe_put("OTEL_EXPORTER_OTLP_PROTOCOL", protocol)
      |> maybe_put("OTEL_EXPORTER_OTLP_ENDPOINT", endpoint)
      |> maybe_put("OTEL_RESOURCE_ATTRIBUTES", resource_attrs)
      |> Enum.reverse()
    else
      []
    end
  end

  # Claude Code requires CLAUDE_CODE_ENABLE_TELEMETRY=1 to emit any signals and
  # CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1 to enable span tracing.
  defp put_backend_vars(entries, "claude", include_traces) do
    entries
    |> maybe_put("CLAUDE_CODE_ENABLE_TELEMETRY", "1")
    |> maybe_put("CLAUDE_CODE_ENHANCED_TELEMETRY_BETA", include_traces && "1")
  end

  defp put_backend_vars(entries, _backend, _include_traces), do: entries

  defp maybe_put(entries, _key, nil), do: entries
  defp maybe_put(entries, _key, false), do: entries
  defp maybe_put(entries, _key, ""), do: entries
  defp maybe_put(entries, key, value), do: [{key, to_string(value)} | entries]
end
