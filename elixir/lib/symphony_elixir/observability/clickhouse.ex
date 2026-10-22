defmodule SymphonyElixir.Observability.ClickHouse do
  @moduledoc """
  Reads agent telemetry from the OpenTelemetry collector's ClickHouse tables
  (`otel_metrics_sum`, `otel_metrics_histogram`, `otel_logs`, `otel_traces`)
  over the ClickHouse HTTP interface.

  Every value that comes from a caller travels as a typed query parameter
  (`{name:Type}` placeholders sent as `param_name`); only column names chosen
  from fixed lists in this module are spliced into SQL. Requests send no
  ClickHouse settings, so a `readonly=1` user works (64-bit integers then come
  back as JSON strings and are parsed). Each request has a short client
  timeout, and errors are returned, never raised.

  Metric temporality: delta series are summed. Cumulative series
  (`AggregationTemporality = 2`) contribute `max - min` per series and time
  bucket, which slightly undercounts the first increment in each bucket.

  `config` is the map from `SymphonyElixir.Config.observability_clickhouse/0`.
  """

  @type config :: %{
          required(:url) => String.t(),
          optional(:user) => String.t() | nil,
          optional(:password) => String.t() | nil,
          optional(:database) => String.t() | nil,
          optional(:timeout_ms) => pos_integer()
        }
  @typedoc """
  `issue` keeps one issue; `team` issues whose identifier starts with that team
  key (`PAY` keeps `PAY-1`); `teams` issues of any of those teams (none for an
  empty list: what a viewer without teams sees); `issues` only those
  identifiers (a project's).
  """
  @type filters :: %{
          optional(:issue) => String.t() | nil,
          optional(:instance) => String.t() | nil,
          optional(:team) => String.t() | nil,
          optional(:teams) => [String.t()] | nil,
          optional(:issues) => [String.t()] | nil
        }
  @type row :: %{String.t() => term()}

  # A bucket this wide puts every timestamp into bucket 0 (no time split).
  @no_bucket 4_294_967_295
  @fact_dims ~w(bucket backend issue model tool)
  @error_statuses ["Error", "STATUS_CODE_ERROR"]

  # Codex emits these spans tens of thousands of times per turn; they drown a waterfall.
  @noisy_spans ~w(append_items persist_rollout_items realtime_conversation.running_state receiving handle_responses auth)
  @dropped_span_attributes ~w(code.file.path code.line.number code.module.name code.namespace thread.id thread.name busy_ns
                              idle_ns target)
  @dropped_log_attributes ~w(prompt prompt_text response output arguments user.id client_request_id)

  @sum_metrics ~w(claude_code.token.usage claude_code.cost.usage claude_code.lines_of_code.count claude_code.commit.count
                  claude_code.active_time.total codex.tool.call codex.api_request codex.conversation.turn.count)
  @claude_events ~w(claude_code.tool_result claude_code.api_request claude_code.api_error claude_code.user_prompt)

  @backend_sql """
  if(ResourceAttributes['symphony.backend'] != '', ResourceAttributes['symphony.backend'],
    multiIf(ServiceName = 'claude-code', 'claude', startsWith(ServiceName, 'codex'), 'codex', ServiceName))
  """

  @bucket_sql "intDiv(toUnixTimestamp(TimeUnix), {bucket:UInt32}) * {bucket:UInt32}"
  @series_key_sql "if(AggregationTemporality = 2, StartTimeUnix, toDateTime64(0, 9))"

  # ------------------------------------------------------------------ queries

  @doc """
  Usage facts summed per `dims` (any of #{inspect(@fact_dims)}) and measure,
  from Claude and Codex metrics plus Claude events.

  Rows: `%{"measure" => String.t(), "value" => number(), <dim> => ...}` with
  `"bucket"` as unix seconds. Measures: `tokens_input` (uncached),
  `tokens_output`, `tokens_cache_read`, `tokens_cache_creation`, `cost_usd`,
  `tool_calls`, `tool_errors`, `api_requests`, `api_errors`, `turns`,
  `lines_added`, `lines_removed`, `commits`, `active_seconds`.

  Options: `:from_ms` (required), `:bucket` (seconds, for the `bucket` dim) and
  `:measures` (restrict to these measures).
  """
  @spec facts(config(), [String.t()], filters(), keyword()) :: {:ok, [row()]} | {:error, term()}
  def facts(config, dims, filters, opts) do
    dims = Enum.filter(@fact_dims, &(&1 in dims))
    group = Enum.join(dims ++ ["measure"], ", ")
    measures = Keyword.get(opts, :measures)
    measure_filter = if measures, do: "has({measures:Array(String)}, measure)", else: "measure != 'other'"

    sql = """
    SELECT #{group}, sum(v) AS value
    FROM (
      #{sum_facts_sql(filters)}
      UNION ALL
      #{histogram_facts_sql(filters)}
      UNION ALL
      #{log_facts_sql(filters)}
    )
    WHERE #{measure_filter}
    GROUP BY #{group}
    ORDER BY #{group}
    """

    params =
      filter_params(filters)
      |> Map.merge(%{from_ms: Keyword.fetch!(opts, :from_ms), bucket: Keyword.get(opts, :bucket, @no_bucket)})
      |> maybe_param(:measures, measures)

    query(config, sql, params)
  end

  defp sum_facts_sql(filters) do
    """
    SELECT bucket, backend, issue, model, tool, m.1 AS measure, m.2 * v AS v
    FROM (
      SELECT #{@bucket_sql} AS bucket,
        #{@backend_sql} AS backend,
        ResourceAttributes['linear.issue.identifier'] AS issue,
        Attributes['model'] AS model,
        if(MetricName = 'codex.tool.call', Attributes['tool'], '') AS tool,
        multiIf(
          MetricName = 'claude_code.token.usage', [(multiIf(
            Attributes['type'] = 'input', 'tokens_input',
            Attributes['type'] = 'output', 'tokens_output',
            Attributes['type'] = 'cacheRead', 'tokens_cache_read',
            Attributes['type'] = 'cacheCreation', 'tokens_cache_creation', 'other'), 1.)],
          MetricName = 'claude_code.cost.usage', [('cost_usd', 1.)],
          MetricName = 'claude_code.lines_of_code.count', [(if(Attributes['type'] = 'removed', 'lines_removed', 'lines_added'), 1.)],
          MetricName = 'claude_code.commit.count', [('commits', 1.)],
          MetricName = 'claude_code.active_time.total', [('active_seconds', 1.)],
          MetricName = 'codex.tool.call',
            if(Attributes['success'] = 'false', [('tool_calls', 1.), ('tool_errors', 1.)], [('tool_calls', 1.)]),
          MetricName = 'codex.api_request',
            if(Attributes['success'] = 'false', [('api_requests', 1.), ('api_errors', 1.)], [('api_requests', 1.)]),
          MetricName = 'codex.conversation.turn.count', [('turns', 1.)],
          [('other', 1.)]) AS measures,
        if(AggregationTemporality = 2, max(Value) - min(Value), sum(Value)) AS v
      FROM otel_metrics_sum
      WHERE TimeUnix >= fromUnixTimestamp64Milli({from_ms:Int64})
        AND MetricName IN (#{sql_list(@sum_metrics)})#{filter_sql(filters)}
      GROUP BY bucket, ServiceName, MetricName, Attributes, ResourceAttributes, AggregationTemporality, #{@series_key_sql}
    )
    ARRAY JOIN measures AS m
    """
  end

  # Codex reports tokens per turn as a histogram whose `input` includes `cached_input`.
  defp histogram_facts_sql(filters) do
    """
    SELECT bucket, backend, issue, model, '' AS tool, m.1 AS measure, m.2 * v AS v
    FROM (
      SELECT #{@bucket_sql} AS bucket,
        #{@backend_sql} AS backend,
        ResourceAttributes['linear.issue.identifier'] AS issue,
        Attributes['model'] AS model,
        multiIf(
          Attributes['token_type'] = 'input', [('tokens_input', 1.)],
          Attributes['token_type'] = 'cached_input', [('tokens_cache_read', 1.), ('tokens_input', -1.)],
          Attributes['token_type'] = 'output', [('tokens_output', 1.)],
          Attributes['token_type'] = 'cache_write_input', [('tokens_cache_creation', 1.)],
          [('other', 1.)]) AS measures,
        if(AggregationTemporality = 2, max(Sum) - min(Sum), sum(Sum)) AS v
      FROM otel_metrics_histogram
      WHERE TimeUnix >= fromUnixTimestamp64Milli({from_ms:Int64})
        AND MetricName = 'codex.turn.token_usage'#{filter_sql(filters)}
      GROUP BY bucket, ServiceName, MetricName, Attributes, ResourceAttributes, AggregationTemporality, #{@series_key_sql}
    )
    ARRAY JOIN measures AS m
    """
  end

  # Claude Code has no tool/request/turn counters, so those come from its events.
  defp log_facts_sql(filters) do
    """
    SELECT intDiv(toUnixTimestamp(TimestampTime), {bucket:UInt32}) * {bucket:UInt32} AS bucket,
      #{@backend_sql} AS backend,
      ResourceAttributes['linear.issue.identifier'] AS issue,
      LogAttributes['model'] AS model,
      if(Body = 'claude_code.tool_result', LogAttributes['tool_name'], '') AS tool,
      m.1 AS measure, m.2 AS v
    FROM otel_logs
    ARRAY JOIN multiIf(
      Body = 'claude_code.tool_result',
        if(LogAttributes['success'] = 'false', [('tool_calls', 1.), ('tool_errors', 1.)], [('tool_calls', 1.)]),
      Body = 'claude_code.api_error', [('api_requests', 1.), ('api_errors', 1.)],
      Body = 'claude_code.api_request', [('api_requests', 1.)],
      [('turns', 1.)]) AS m
    WHERE ServiceName = 'claude-code'
      AND TimestampTime >= toDateTime(intDiv({from_ms:Int64}, 1000))
      AND Body IN (#{sql_list(@claude_events)})#{filter_sql(filters)}
    """
  end

  @doc """
  Model API latency inputs per backend: Codex's `codex.api_request.duration_ms`
  histogram and Claude's `claude_code.api_request` event durations.

  Rows: `%{"backend" => _, "kind" => "histogram", "bounds" => [number], "counts" => [integer]}`
  and `%{"backend" => _, "kind" => "quantiles", "p50" => number | nil, "p95" => number | nil, "count" => integer}`.
  """
  @spec latency(config(), filters(), keyword()) :: {:ok, [row()]} | {:error, term()}
  def latency(config, filters, opts) do
    params = Map.put(filter_params(filters), :from_ms, Keyword.fetch!(opts, :from_ms))

    histogram_sql = """
    SELECT backend, 'histogram' AS kind, bounds, sumForEach(counts) AS counts
    FROM (
      SELECT #{@backend_sql} AS backend, ExplicitBounds AS bounds,
        if(AggregationTemporality = 2,
          arrayMap((a, b) -> toInt64(a) - toInt64(b), argMax(BucketCounts, TimeUnix), argMin(BucketCounts, TimeUnix)),
          arrayMap(x -> toInt64(x), sumForEach(BucketCounts))) AS counts
      FROM otel_metrics_histogram
      WHERE TimeUnix >= fromUnixTimestamp64Milli({from_ms:Int64})
        AND MetricName = 'codex.api_request.duration_ms'#{filter_sql(filters)}
      GROUP BY ServiceName, Attributes, ResourceAttributes, ExplicitBounds, AggregationTemporality, #{@series_key_sql}
    )
    GROUP BY backend, bounds
    """

    quantile_sql = """
    SELECT #{@backend_sql} AS backend, 'quantiles' AS kind,
      quantiles(0.5, 0.95)(toFloat64OrNull(LogAttributes['duration_ms'])) AS q, count() AS count
    FROM otel_logs
    WHERE ServiceName = 'claude-code'
      AND TimestampTime >= toDateTime(intDiv({from_ms:Int64}, 1000))
      AND Body = 'claude_code.api_request'#{filter_sql(filters)}
    GROUP BY backend
    """

    with {:ok, histograms} <- query(config, histogram_sql, params),
         {:ok, quantiles} <- query(config, quantile_sql, params) do
      {:ok, histograms ++ Enum.map(quantiles, &quantile_row/1)}
    end
  end

  defp quantile_row(row) do
    [p50, p95] =
      case row["q"] do
        [p50, p95] -> [number_or_nil(p50), number_or_nil(p95)]
        _ -> [nil, nil]
      end

    row |> Map.delete("q") |> Map.merge(%{"p50" => p50, "p95" => p95, "count" => number(row["count"])})
  end

  @doc """
  Recent traces that carry `filters.issue`, newest first. Codex sends many tiny
  housekeeping traces, so only traces with at least `:min_spans` spans (10 by
  default) or a session root (`session_loop`, `claude_code.interaction`) count.

  Rows: `trace_id`, `span_count`, `started_ms`, `duration_ms` (first span start
  to last span end), `root_name`, `service`, `backend`, `error_count`.
  """
  @spec traces(config(), filters(), keyword()) :: {:ok, [row()]} | {:error, term()}
  def traces(config, filters, opts) do
    sql = """
    SELECT TraceId AS trace_id, count() AS span_count,
      toUnixTimestamp64Milli(min(Timestamp)) AS started_ms,
      intDiv(max(toUnixTimestamp64Nano(Timestamp) + toInt64(Duration)) - min(toUnixTimestamp64Nano(Timestamp)), 1000000)
        AS duration_ms,
      if(anyIf(SpanName, ParentSpanId = '') != '', anyIf(SpanName, ParentSpanId = ''), argMin(SpanName, Timestamp))
        AS root_name,
      any(ServiceName) AS service,
      any(#{@backend_sql}) AS backend,
      countIf(StatusCode IN (#{sql_list(@error_statuses)})) AS error_count
    FROM otel_traces
    WHERE Timestamp >= fromUnixTimestamp64Milli({from_ms:Int64})#{filter_sql(filters)}
    GROUP BY TraceId
    HAVING span_count >= {min_spans:UInt32} OR root_name IN ('session_loop', 'claude_code.interaction', 'symphony.run')
    ORDER BY started_ms DESC
    LIMIT {limit:UInt32}
    """

    params =
      filters
      |> filter_params()
      |> Map.merge(%{
        from_ms: Keyword.fetch!(opts, :from_ms),
        min_spans: Keyword.get(opts, :min_spans, 10),
        limit: Keyword.get(opts, :limit, 20)
      })

    query(config, sql, params)
  end

  @doc """
  Size and time bounds of one trace: `%{"span_count", "started_ms", "ended_ms",
  "error_count"}`, or `{:error, :not_found}`.
  """
  @spec trace_summary(config(), String.t()) :: {:ok, row()} | {:error, term()}
  def trace_summary(config, trace_id) do
    sql = """
    SELECT count() AS span_count,
      toUnixTimestamp64Milli(min(Timestamp)) AS started_ms,
      intDiv(max(toUnixTimestamp64Nano(Timestamp) + toInt64(Duration)), 1000000) AS ended_ms,
      countIf(StatusCode IN (#{sql_list(@error_statuses)})) AS error_count
    FROM otel_traces
    WHERE #{trace_where()}
    """

    case query(config, sql, %{trace_id: trace_id}) do
      {:ok, [%{"span_count" => count} = row]} ->
        if number(count) > 0, do: {:ok, Map.new(row, fn {key, value} -> {key, number(value)} end)}, else: {:error, :not_found}

      {:ok, _rows} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  @doc """
  The spans of one trace worth drawing: the root, errors, and spans of at least
  `:min_duration_ms` (1 by default) that are not Codex's per-chunk noise; the
  `:limit` (500 by default) longest of those.

  Rows: `span_id`, `parent_span_id`, `name`, `service`, `kind`, `start_us`,
  `duration_ns`, `status_code`, `status_message`, `attributes` (map).
  """
  @spec trace_spans(config(), String.t(), keyword()) :: {:ok, [row()]} | {:error, term()}
  def trace_spans(config, trace_id, opts) do
    sql = """
    SELECT SpanId AS span_id, ParentSpanId AS parent_span_id, SpanName AS name, ServiceName AS service,
      SpanKind AS kind, toUnixTimestamp64Micro(Timestamp) AS start_us, Duration AS duration_ns,
      StatusCode AS status_code, StatusMessage AS status_message,
      mapFilter((k, v) -> NOT has({dropped:Array(String)}, k), SpanAttributes) AS attributes
    FROM otel_traces
    WHERE #{trace_where()}
      AND (ParentSpanId = '' OR StatusCode IN (#{sql_list(@error_statuses)})
        OR (NOT has({noisy:Array(String)}, SpanName) AND Duration >= {min_duration_ns:UInt64}))
    ORDER BY ParentSpanId = '' DESC, StatusCode IN (#{sql_list(@error_statuses)}) DESC, Duration DESC
    LIMIT {limit:UInt32}
    """

    params = %{
      trace_id: trace_id,
      dropped: @dropped_span_attributes,
      noisy: Keyword.get(opts, :noisy_spans, @noisy_spans),
      min_duration_ns: round(Keyword.get(opts, :min_duration_ms, 1) * 1_000_000),
      limit: Keyword.get(opts, :limit, 500)
    }

    query(config, sql, params)
  end

  # otel_traces is ordered by service, span name and time, so bound the time
  # range from the exporter's trace-id lookup table before matching TraceId.
  defp trace_where do
    """
    TraceId = {trace_id:String}
      AND Timestamp >= (SELECT min(Start) FROM otel_traces_trace_id_ts WHERE TraceId = {trace_id:String}) - INTERVAL 1 MINUTE
      AND Timestamp <= (SELECT max(End) FROM otel_traces_trace_id_ts WHERE TraceId = {trace_id:String}) + INTERVAL 1 MINUTE
    """
  end

  @doc """
  Recent agent events for `filters.issue`, newest first. `:events` picks event
  names (default: tool results and API errors from both backends); with
  `errors_only: true` only failed tool results and API errors are returned.

  Rows: `at_ms`, `event`, `backend`, `trace_id`, `severity`, `attributes` (map,
  without prompt/response bodies).
  """
  @spec logs(config(), filters(), keyword()) :: {:ok, [row()]} | {:error, term()}
  def logs(config, filters, opts) do
    errors_sql =
      if Keyword.get(opts, :errors_only, false) do
        "\n  AND (LogAttributes['success'] = 'false' OR endsWith(event, 'api_error'))"
      else
        ""
      end

    sql = """
    SELECT toUnixTimestamp64Milli(Timestamp) AS at_ms,
      if(startsWith(Body, 'claude_code.'), Body, LogAttributes['event.name']) AS event,
      #{@backend_sql} AS backend,
      TraceId AS trace_id, SeverityText AS severity,
      mapFilter((k, v) -> NOT has({dropped:Array(String)}, k), LogAttributes) AS attributes
    FROM otel_logs
    WHERE TimestampTime >= toDateTime(intDiv({from_ms:Int64}, 1000))
      AND has({events:Array(String)}, event)#{filter_sql(filters)}#{errors_sql}
    ORDER BY Timestamp DESC
    LIMIT {limit:UInt32}
    """

    params =
      filters
      |> filter_params()
      |> Map.merge(%{
        from_ms: Keyword.fetch!(opts, :from_ms),
        events: Keyword.get(opts, :events, ["claude_code.tool_result", "claude_code.api_error", "codex.tool_result"]),
        dropped: @dropped_log_attributes,
        limit: Keyword.get(opts, :limit, 50)
      })

    query(config, sql, params)
  end

  # ------------------------------------------------------------------ HTTP

  @doc """
  Runs one read query (`FORMAT JSON` is appended) and returns its rows as maps.
  `params` values are sent as typed query parameters.
  """
  @spec query(config(), String.t(), map()) :: {:ok, [row()]} | {:error, term()}
  def query(config, sql, params \\ %{}) do
    timeout = Map.get(config, :timeout_ms) || 3_000

    # No per-query settings: a `readonly=1` user is refused any setting change,
    # so 64-bit integers arrive as JSON strings and are parsed by `number/1`.
    query_params =
      [database: Map.get(config, :database) || "otel"] ++
        Enum.map(params, fn {name, value} -> {"param_#{name}", encode_param(value)} end)

    request =
      [
        url: config.url,
        body: String.trim_trailing(sql) <> "\nFORMAT JSON",
        params: query_params,
        headers: [{"content-type", "text/plain; charset=utf-8"}],
        receive_timeout: timeout,
        connect_options: [timeout: timeout],
        retry: false,
        decode_body: false
      ]
      |> maybe_auth(config)

    case Req.post(request ++ Application.get_env(:symphony_elixir, :observability_req_options, [])) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode(body)
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:clickhouse_http, status, error_message(body)}}
      {:error, exception} -> {:error, {:clickhouse_unreachable, Map.get(exception, :reason, exception)}}
    end
  end

  defp maybe_auth(request, %{user: user} = config) when is_binary(user) do
    Keyword.put(request, :auth, {:basic, "#{user}:#{Map.get(config, :password) || ""}"})
  end

  defp maybe_auth(request, _config), do: request

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode(decoded)
      {:error, _} -> {:error, :invalid_clickhouse_response}
    end
  end

  defp decode(%{"data" => rows}) when is_list(rows), do: {:ok, rows}
  defp decode(_body), do: {:error, :invalid_clickhouse_response}

  # Bodies are never decoded here (decode_body: false), so they are binaries.
  defp error_message(body), do: body |> String.trim() |> String.slice(0, 300)

  # ClickHouse reads parameter values in its escaped text format.
  @doc false
  @spec encode_param(term()) :: String.t()
  def encode_param(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &("'" <> escape(to_string(&1)) <> "'")) <> "]"
  def encode_param(value) when is_binary(value), do: String.replace(value, "\\", "\\\\")
  def encode_param(value), do: to_string(value)

  defp escape(value), do: value |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")

  # ------------------------------------------------------------------ helpers

  defp filter_sql(filters) do
    issue = if present?(filters[:issue]), do: "\n  AND ResourceAttributes['linear.issue.identifier'] = {issue:String}", else: ""
    team = if present?(filters[:team]), do: "\n  AND startsWith(ResourceAttributes['linear.issue.identifier'], {team_prefix:String})", else: ""

    teams =
      if is_list(filters[:teams]),
        do: "\n  AND arrayExists(p -> startsWith(ResourceAttributes['linear.issue.identifier'], p), {team_prefixes:Array(String)})",
        else: ""

    issues =
      if is_list(filters[:issues]),
        do: "\n  AND has({issues:Array(String)}, ResourceAttributes['linear.issue.identifier'])",
        else: ""

    instance =
      if present?(filters[:instance]),
        do: "\n  AND ResourceAttributes['symphony.instance'] IN ({instance:String}, {instance_encoded:String})",
        else: ""

    issue <> team <> teams <> issues <> instance
  end

  # Codex does not percent-decode OTEL_RESOURCE_ATTRIBUTES, so match both spellings.
  defp filter_params(filters) do
    %{}
    |> maybe_param(:issue, if(present?(filters[:issue]), do: filters[:issue]))
    |> maybe_param(:team_prefix, if(present?(filters[:team]), do: filters[:team] <> "-"))
    |> maybe_param(:team_prefixes, if(is_list(filters[:teams]), do: Enum.map(filters[:teams], &(&1 <> "-"))))
    |> maybe_param(:issues, if(is_list(filters[:issues]), do: filters[:issues]))
    |> then(fn params ->
      if present?(filters[:instance]) do
        Map.merge(params, %{instance: filters[:instance], instance_encoded: URI.encode(filters[:instance], &resource_char?/1)})
      else
        params
      end
    end)
  end

  defp resource_char?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c"-_.~/"

  defp maybe_param(params, _name, nil), do: params
  defp maybe_param(params, name, value), do: Map.put(params, name, value)

  defp present?(value), do: is_binary(value) and value != ""

  defp sql_list(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  @doc false
  @spec number(term()) :: number()
  def number(value) when is_number(value), do: value

  def number(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> if float == trunc(float) and not String.contains?(value, "."), do: trunc(float), else: float
      _ -> 0
    end
  end

  def number(_value), do: 0

  @doc false
  @spec number_or_nil(term()) :: number() | nil
  def number_or_nil(value) when is_number(value), do: value

  def number_or_nil(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> nil
    end
  end

  def number_or_nil(_value), do: nil
end
