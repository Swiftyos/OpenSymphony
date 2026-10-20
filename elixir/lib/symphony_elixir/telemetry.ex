defmodule SymphonyElixir.Telemetry do
  @moduledoc """
  Builds OpenTelemetry environment variable pairs for agent backend sessions,
  plus the `-c otel.*` overrides Codex needs in place of most of them.

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
      |> maybe_put("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", Config.telemetry_otlp_traces_endpoint())
      |> maybe_put("OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", Config.telemetry_otlp_traces_protocol())
      |> maybe_put("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", Config.telemetry_otlp_logs_endpoint())
      |> maybe_put("OTEL_EXPORTER_OTLP_LOGS_PROTOCOL", Config.telemetry_otlp_logs_protocol())
      |> maybe_put("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", Config.telemetry_otlp_metrics_endpoint())
      |> maybe_put("OTEL_EXPORTER_OTLP_METRICS_PROTOCOL", Config.telemetry_otlp_metrics_protocol())
      |> maybe_put("OTEL_LOG_USER_PROMPTS", settings.telemetry.log_user_prompts && "1")
      |> maybe_put("OTEL_LOG_TOOL_DETAILS", settings.telemetry.log_tool_details && "1")
      |> maybe_put("OTEL_RESOURCE_ATTRIBUTES", resource_attrs)
      |> Enum.reverse()
    else
      []
    end
  end

  @doc """
  Codex `-c` overrides that make Codex export OpenTelemetry.

  Codex ignores the OTEL_*_EXPORTER/ENDPOINT variables and only exports what its
  `[otel]` config names, so the telemetry settings are translated into
  `otel.*` overrides. Each entry is an unquoted `key=value` TOML assignment.
  Resource attributes still travel in OTEL_RESOURCE_ATTRIBUTES (see
  `env_pairs/3`), which the Rust SDK's resource detector reads.

  Returns `[]` when telemetry is disabled or no signal has an endpoint.
  """
  @spec codex_config_overrides(map() | nil) :: [String.t()]
  def codex_config_overrides(issue \\ nil) do
    telemetry = Config.settings!().telemetry

    exporters =
      if telemetry.enabled do
        [
          {"otel.exporter", telemetry.include_logs && codex_exporter(telemetry, "logs")},
          {"otel.trace_exporter", telemetry.include_traces && codex_exporter(telemetry, "traces")},
          {"otel.metrics_exporter", telemetry.include_metrics && codex_exporter(telemetry, "metrics")}
        ]
      else
        []
      end

    if Enum.any?(exporters, fn {_key, exporter} -> exporter end) do
      Enum.flat_map(exporters, &codex_exporter_overrides/1) ++
        [
          "otel.log_user_prompt=#{telemetry.log_user_prompts}",
          # Responses are conversation content like prompts, so they share its
          # opt-in; log_tool_details only covers tool arguments.
          "otel.log_agent_responses=#{telemetry.log_user_prompts}",
          "otel.environment=#{toml_string(codex_environment(telemetry.resource_attributes, issue))}"
        ]
    else
      []
    end
  end

  # Codex falls back to `otel.exporter` for traces when `trace_exporter` is
  # unset, so a disabled log/trace signal is pinned to "none" rather than left
  # to inherit the other signal's URL. Metrics are only touched when enabled:
  # Codex additionally gates metric emission on `analytics.enabled`.
  defp codex_exporter_overrides({"otel.metrics_exporter" = key, exporter}) when is_binary(exporter),
    do: ["#{key}=#{exporter}", "analytics.enabled=true"]

  defp codex_exporter_overrides({"otel.metrics_exporter", _exporter}), do: []
  defp codex_exporter_overrides({key, exporter}) when is_binary(exporter), do: ["#{key}=#{exporter}"]
  defp codex_exporter_overrides({key, _exporter}), do: [~s(#{key}="none")]

  # A per-signal endpoint is used as given. Codex's otlp-http exporter posts to
  # the endpoint verbatim, so the shared endpoint gets the /v1/<signal> path the
  # OTLP spec would otherwise add; gRPC takes the bare collector address.
  defp codex_exporter(telemetry, signal) do
    signal_endpoint = normalize(Map.fetch!(telemetry, :"otlp_#{signal}_endpoint"))
    protocol = normalize(Map.fetch!(telemetry, :"otlp_#{signal}_protocol")) || normalize(telemetry.otlp_protocol) || "grpc"

    endpoint =
      cond do
        signal_endpoint -> signal_endpoint
        endpoint = normalize(telemetry.otlp_endpoint) -> otlp_signal_endpoint(endpoint, protocol, signal)
        true -> nil
      end

    endpoint && codex_exporter_table(protocol, endpoint)
  end

  defp otlp_signal_endpoint(endpoint, "grpc", _signal), do: endpoint
  defp otlp_signal_endpoint(endpoint, _protocol, signal), do: String.trim_trailing(endpoint, "/") <> "/v1/" <> signal

  defp codex_exporter_table("grpc", endpoint),
    do: ~s({ otlp-grpc = { endpoint = #{toml_string(endpoint)} } })

  defp codex_exporter_table(protocol, endpoint),
    do: ~s({ otlp-http = { endpoint = #{toml_string(endpoint)}, protocol = "#{codex_http_protocol(protocol)}" } })

  defp codex_http_protocol("http/json"), do: "json"
  defp codex_http_protocol(_protocol), do: "binary"

  # The configured deployment environment wins; otherwise each issue gets its
  # own, as before resource attributes carried the issue identifier.
  defp codex_environment(%{"environment" => environment}, _issue) when is_binary(environment), do: environment

  defp codex_environment(_resource_attributes, issue) when is_map(issue),
    do: "symphony-#{Map.get(issue, :identifier) || Map.get(issue, "identifier") || "unknown"}"

  defp codex_environment(_resource_attributes, _issue), do: "symphony-unknown"

  defp toml_string(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"" <> escaped <> "\""
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_value), do: nil

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
  defp maybe_put(entries, key, value), do: [{key, to_string(value)} | entries]
end
