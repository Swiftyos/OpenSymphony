defmodule SymphonyElixir.Observability do
  @moduledoc """
  Read-side metrics and traces for the dashboard, from the ClickHouse tables the
  OpenTelemetry collector writes and from Langfuse.

  Configure under `observability` (see the README). Without the needed source
  every function returns `{:error, :not_configured}`; other failures come back as
  `{:error, reason}` and nothing raises. Requests time out after
  `observability.timeout_ms` (3 s) and results are cached for
  `observability.cache_ttl_ms` (30 s), so these calls are cheap to repeat, but
  a cold call can take a few seconds: call them from an async assign, not
  inside `mount/3` or `handle_info/2` directly.

  ## Ranges

  `range` is `:hour`, `:day`, `:week`, `:month`, or a number of seconds. Chart
  buckets are 5 min, 1 h, 6 h and 1 day (a custom range gets about 60 points,
  at least 60 s each).

  ## Shapes

  All keys are atoms except backend names (`symphony.backend` values such as
  `"codex"`, `"claude"`) used as map keys. A value that cannot be derived is nil.

  `status/0`:

      %{clickhouse: %{state: :ok | :not_configured | :error, error: term | nil},
        langfuse: %{state: ..., error: ...}}

  `totals`:

      %{tokens: n, input_tokens: n, output_tokens: n, cache_read_tokens: n, cache_creation_tokens: n,
        cost_usd: float, estimated_cost_usd: float,   # estimated = priced by `pricing`, included in cost_usd
        turns: n, tool_calls: n, tool_errors: n, api_requests: n, api_errors: n,
        api_p50_ms: float | nil, api_p95_ms: float | nil,
        lines_added: n, lines_removed: n, commits: n, active_seconds: n}

  `tokens` is the sum of the four token kinds. `input_tokens` is uncached input
  for both backends (Codex's input minus its cached input). Claude's cost is
  what Claude Code reports; Codex's is estimated from `pricing`. Codex turns are
  `codex.conversation.turn.count`; Claude turns are user prompts. The overall
  `api_p50_ms`/`api_p95_ms` are request-weighted means of the per-backend
  percentiles in `api_latency_ms` (Codex's interpolated from its histogram).

  `series`: `%{tokens: points, cost: points, tool_calls: points}` with
  `points = [%{at: DateTime, values: %{"codex" => n, "claude" => n}}]`, oldest
  first, one per bucket, empty buckets and absent backends filled with 0.

  `factory_overview/2` returns:

      %{range, from: DateTime, to: DateTime, bucket_seconds,
        totals: totals, series: series,
        by_backend: %{"codex" => totals, ...},
        by_model: [%{model, backend, tokens, input_tokens, output_tokens, cache_read_tokens,
                     cache_creation_tokens, cost_usd, api_requests}],
        top_tools: [%{name, backend, calls, errors}],      # by calls, max 10
        top_issues: [%{identifier, title: nil, tokens, cost_usd, backends, tool_calls, turns}],
                                                           # by cost, then tokens, max 10
        api_latency_ms: %{"codex" => %{p50, p95, count}, ...}}

  `issue_metrics/3` returns the same without `top_issues`, plus `identifier`.

  `issue_traces/2` returns, newest first:

      [%{id, name, started_at: DateTime, duration_ms, span_count, error: boolean,
         error_count, trace_id, backend, service, langfuse_url: String.t() | nil}]

  `trace/2` returns:

      %{id, url: String.t() | nil, spans: [span],
        trace_id, source: :langfuse | :clickhouse, name, started_at: DateTime,
        duration_ms, span_count, shown_spans, truncated: boolean, error: boolean,
        cost_usd: float | nil, langfuse_url}

      span = %{id, parent_id, name, start_ms, duration_ms, status: "ok" | "error",
               detail: String.t() | nil,           # status message, model, tokens, cost
               type, service, start_offset_ms, otel_status: :ok | :error | :warning | :unset,
               status_message, model, cost_usd: float | nil,
               usage: %{optional(:input | :output | :cache_read | :cache_creation | :total) => n} | nil,
               attributes: %{String.t() => String.t()}}

  `start_ms` is the offset from the trace start. Spans are sorted by start. Big
  traces (Codex turns reach 250k spans) are cut to `:max_spans` (500): the
  root, errors and the longest spans, leaving out Codex's per-chunk spans. A
  span whose parent was cut has `parent_id: nil`.

  `issue_logs/2` returns `[event]`:

      %{at: DateTime, event, backend, trace_id, severity, tool, success: boolean | nil,
        duration_ms, error, model, attributes}
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Observability.{Cache, ClickHouse, Langfuse, Metrics}

  @ranges %{hour: {3_600, 300}, day: {86_400, 3_600}, week: {604_800, 21_600}, month: {2_592_000, 86_400}}
  @series_measures ~w(tokens_input tokens_output tokens_cache_read tokens_cache_creation cost_usd tool_calls)
  @project_ttl_ms 600_000
  @attribute_value_limit 500
  @attribute_count_limit 60

  @type range :: :hour | :day | :week | :month | pos_integer()
  @type error :: {:error, :not_configured | :invalid_range | :invalid_identifier | :invalid_trace_id | term()}

  @doc "Which sources are configured."
  @spec configured() :: %{clickhouse: boolean(), langfuse: boolean()}
  def configured do
    %{clickhouse: Config.observability_clickhouse() != nil, langfuse: Config.observability_langfuse() != nil}
  end

  @doc """
  Whether each source answers: `%{clickhouse: source, langfuse: source}` with
  `source = %{state: :ok | :not_configured | :error, error: term() | nil}`.
  Probes with `SELECT 1` and `GET /api/public/projects`; cached for the
  cache TTL, so it is cheap to call on every page load.
  """
  @spec status() :: %{clickhouse: map(), langfuse: map()}
  def status do
    cached(:status, fn ->
      clickhouse = Task.async(fn -> probe(Config.observability_clickhouse(), &ClickHouse.query(&1, "SELECT 1 AS ok")) end)
      langfuse = Task.async(fn -> probe(Config.observability_langfuse(), &Langfuse.project_id/1) end)
      # Wrapped in :ok so a failing source is remembered for the full TTL too.
      {:ok, %{clickhouse: Task.await(clickhouse, :infinity), langfuse: Task.await(langfuse, :infinity)}}
    end)
    |> elem(1)
  end

  defp probe(nil, _check), do: %{state: :not_configured, error: nil}

  defp probe(config, check) do
    case check.(config) do
      {:ok, _} -> %{state: :ok, error: nil}
      {:error, reason} -> %{state: :error, error: reason}
    end
  end

  @doc """
  Factory-wide usage for `range` (see the moduledoc for the shape). Options:
  `instance:` only counts telemetry from that `symphony.instance`; `top:` caps
  the tool and issue lists (10).
  """
  @spec factory_overview(range(), keyword()) :: {:ok, map()} | error()
  def factory_overview(range \\ :day, opts \\ []) do
    with {:ok, window} <- window(range),
         {:ok, clickhouse} <- clickhouse() do
      cached({:factory_overview, range, opts}, fn ->
        load_metrics(clickhouse, window, %{instance: opts[:instance]}, Keyword.get(opts, :top, 10), true)
      end)
    end
  end

  @doc "Usage for one issue (Linear identifier, e.g. `TRUST-758`) over `range`."
  @spec issue_metrics(String.t(), range(), keyword()) :: {:ok, map()} | error()
  def issue_metrics(identifier, range \\ :week, opts \\ []) do
    with {:ok, identifier} <- identifier(identifier),
         {:ok, window} <- window(range),
         {:ok, clickhouse} <- clickhouse() do
      key = {:issue_metrics, identifier, range, opts}
      cached(key, fn -> load_issue_metrics(clickhouse, window, identifier, opts) end)
    end
  end

  defp load_issue_metrics(clickhouse, window, identifier, opts) do
    filters = %{issue: identifier, instance: opts[:instance]}

    with {:ok, metrics} <- load_metrics(clickhouse, window, filters, Keyword.get(opts, :top, 10), false) do
      {:ok, Map.put(metrics, :identifier, identifier)}
    end
  end

  @doc """
  Recent traces of one issue, newest first. Options: `limit:` (20), `range:`
  (`:week`), `min_spans:` (10; smaller traces are Codex housekeeping), and
  `instance:`. Reads ClickHouse; with only Langfuse configured, Langfuse traces
  whose metadata names the issue.
  """
  @spec issue_traces(String.t(), pos_integer() | keyword()) :: {:ok, [map()]} | error()
  def issue_traces(identifier, opts \\ [])

  def issue_traces(identifier, limit) when is_integer(limit) and limit > 0, do: issue_traces(identifier, limit: limit)

  def issue_traces(identifier, opts) when is_list(opts) do
    with {:ok, identifier} <- identifier(identifier),
         {:ok, window} <- window(Keyword.get(opts, :range, :week)) do
      issue_traces_from(Config.observability_clickhouse(), Config.observability_langfuse(), identifier, window, opts)
    end
  end

  defp issue_traces_from(nil, nil, _identifier, _window, _opts), do: {:error, :not_configured}

  defp issue_traces_from(nil, langfuse, identifier, window, opts) do
    cached({:issue_traces, identifier, opts}, fn -> langfuse_traces(langfuse, identifier, window, opts) end)
  end

  defp issue_traces_from(clickhouse, langfuse, identifier, window, opts) do
    key = {:issue_traces, identifier, opts}
    cached(key, fn -> clickhouse_traces(clickhouse, langfuse, identifier, window, opts) end)
  end

  @doc """
  One trace as a flat, waterfall-ready span list. Prefers Langfuse (its
  observations carry usage and cost) unless ClickHouse shows the trace is
  bigger than `max_spans:` (500); falls back to ClickHouse spans. Options:
  `max_spans:`, `min_duration_ms:` (1, ClickHouse only).
  """
  @spec trace(String.t(), keyword()) :: {:ok, map()} | error()
  def trace(trace_id, opts \\ []) do
    with {:ok, trace_id} <- trace_id(trace_id) do
      trace_from(Config.observability_clickhouse(), Config.observability_langfuse(), trace_id, opts)
    end
  end

  @doc """
  Recent agent events of one issue, newest first: tool results and API errors
  by default. Options: `limit:` (50), `range:` (`:week`), `events:` (event
  names, e.g. `["claude_code.api_request"]`), `errors_only:` (false),
  `instance:`.
  """
  @spec issue_logs(String.t(), keyword()) :: {:ok, [map()]} | error()
  def issue_logs(identifier, opts \\ []) do
    with {:ok, identifier} <- identifier(identifier),
         {:ok, window} <- window(Keyword.get(opts, :range, :week)),
         {:ok, clickhouse} <- clickhouse() do
      cached({:issue_logs, identifier, opts}, fn -> load_issue_logs(clickhouse, window, identifier, opts) end)
    end
  end

  defp load_issue_logs(clickhouse, window, identifier, opts) do
    query_opts = [from_ms: window.from_ms] ++ Keyword.take(opts, [:limit, :events, :errors_only])

    with {:ok, rows} <- ClickHouse.logs(clickhouse, %{issue: identifier, instance: opts[:instance]}, query_opts) do
      {:ok, Enum.map(rows, &log_event/1)}
    end
  end

  # ------------------------------------------------------------------ metrics

  defp load_metrics(clickhouse, window, filters, top, overview?) do
    breakdown_dims = if overview?, do: ~w(backend issue model), else: ~w(backend model)
    base = [from_ms: window.from_ms]

    queries = [
      breakdown: fn -> ClickHouse.facts(clickhouse, breakdown_dims, filters, base) end,
      series: fn ->
        ClickHouse.facts(clickhouse, ~w(bucket backend model), filters, base ++ [bucket: window.bucket, measures: @series_measures])
      end,
      tools: fn -> ClickHouse.facts(clickhouse, ~w(backend tool), filters, base ++ [measures: ~w(tool_calls tool_errors)]) end,
      latency: fn -> ClickHouse.latency(clickhouse, filters, base) end
    ]

    with {:ok, results} <- parallel(queries, clickhouse) do
      breakdown = Metrics.prepare(results.breakdown)
      tools = Metrics.prepare(results.tools)
      series = Metrics.prepare(results.series)
      latency = Metrics.latency(results.latency)
      overall = Metrics.overall_latency(latency)

      by_backend =
        Map.new(Metrics.totals_by(breakdown, "backend"), fn {backend, totals} ->
          backend_latency = Map.get(latency, backend, %{})
          {backend, Map.merge(totals, %{api_p50_ms: backend_latency[:p50], api_p95_ms: backend_latency[:p95]})}
        end)

      metrics = %{
        range: window.range,
        from: DateTime.from_unix!(window.from_ms, :millisecond),
        to: DateTime.from_unix!(window.to_ms, :millisecond),
        bucket_seconds: window.bucket,
        totals: breakdown |> Metrics.totals() |> Map.merge(%{api_p50_ms: overall.p50, api_p95_ms: overall.p95}),
        by_backend: by_backend,
        by_model: Metrics.by_model(breakdown),
        series: Metrics.series(series, div(window.from_ms, 1000), div(window.to_ms, 1000), window.bucket, Map.keys(by_backend)),
        top_tools: Metrics.top_tools(tools, top),
        api_latency_ms: latency
      }

      {:ok, if(overview?, do: Map.put(metrics, :top_issues, Metrics.top_issues(breakdown, top)), else: metrics)}
    end
  end

  defp parallel(queries, config) do
    timeout = (Map.get(config, :timeout_ms) || 3_000) + 2_000

    queries
    # Not linked, so a crashing query becomes an error instead of killing the caller.
    |> then(
      &Task.Supervisor.async_stream_nolink(SymphonyElixir.TaskSupervisor, &1, fn {name, fun} -> {name, fun.()} end,
        timeout: timeout,
        on_timeout: :kill_task
      )
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {name, {:ok, rows}}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, name, rows)}}
      {:ok, {_name, {:error, reason}}}, _acc -> {:halt, {:error, reason}}
      {:exit, reason}, _acc -> {:halt, {:error, {:query_failed, reason}}}
    end)
  end

  # ------------------------------------------------------------------ traces

  defp clickhouse_traces(clickhouse, langfuse, identifier, window, opts) do
    query_opts = [from_ms: window.from_ms] ++ Keyword.take(opts, [:limit, :min_spans])

    with {:ok, rows} <- ClickHouse.traces(clickhouse, %{issue: identifier, instance: opts[:instance]}, query_opts) do
      project_id = langfuse && langfuse_project_id(langfuse)

      {:ok,
       Enum.map(rows, fn row ->
         error_count = ClickHouse.number(row["error_count"])

         %{
           id: row["trace_id"],
           trace_id: row["trace_id"],
           name: row["root_name"],
           started_at: from_unix_ms(row["started_ms"]),
           duration_ms: ClickHouse.number(row["duration_ms"]),
           span_count: ClickHouse.number(row["span_count"]),
           error_count: error_count,
           error: error_count > 0,
           backend: blank_to_nil(row["backend"]),
           service: blank_to_nil(row["service"]),
           langfuse_url: langfuse && Langfuse.trace_url(langfuse, row["trace_id"], project_id)
         }
       end)}
    end
  end

  defp langfuse_traces(langfuse, identifier, window, opts) do
    params = [limit: 100, fromTimestamp: DateTime.to_iso8601(DateTime.from_unix!(window.from_ms, :millisecond))]

    with {:ok, traces} <- Langfuse.traces(langfuse, params) do
      {:ok,
       traces
       |> Enum.filter(&names_issue?(&1["metadata"], identifier))
       |> Enum.take(Keyword.get(opts, :limit, 20))
       |> Enum.map(fn trace ->
         %{
           id: trace["id"],
           trace_id: trace["id"],
           name: trace["name"],
           started_at: parse_time(trace["timestamp"]),
           duration_ms: seconds_to_ms(trace["latency"]),
           span_count: length(List.wrap(trace["observations"])),
           error_count: 0,
           error: false,
           backend: find_value(trace["metadata"], "symphony.backend"),
           service: find_value(trace["metadata"], "service.name"),
           langfuse_url: Langfuse.html_url(langfuse, trace["htmlPath"]) || Langfuse.trace_url(langfuse, trace["id"], nil)
         }
       end)}
    end
  end

  defp langfuse_project_id(langfuse) do
    case Cache.fetch({:langfuse_project, langfuse.url, langfuse.public_key}, @project_ttl_ms, fn -> Langfuse.project_id(langfuse) end) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp trace_from(nil, nil, _trace_id, _opts), do: {:error, :not_configured}

  defp trace_from(clickhouse, langfuse, trace_id, opts) do
    cached({:trace, trace_id, opts}, fn -> load_trace(clickhouse, langfuse, trace_id, opts) end)
  end

  defp load_trace(clickhouse, langfuse, trace_id, opts) do
    max_spans = Keyword.get(opts, :max_spans, 500)
    summary = if clickhouse, do: ClickHouse.trace_summary(clickhouse, trace_id), else: {:error, :not_configured}
    too_big? = match?({:ok, %{"span_count" => count}} when count > max_spans, summary)
    langfuse_result = if langfuse && not too_big?, do: Langfuse.trace(langfuse, trace_id), else: :skip

    case langfuse_result do
      {:ok, trace} ->
        {:ok, langfuse |> langfuse_trace(trace, max_spans) |> present_trace()}

      _ when clickhouse != nil ->
        with {:ok, trace} <- clickhouse_trace(clickhouse, langfuse, trace_id, summary, max_spans, opts) do
          {:ok, present_trace(trace)}
        end

      error ->
        error
    end
  end

  defp clickhouse_trace(_clickhouse, _langfuse, _trace_id, {:error, _} = error, _max_spans, _opts), do: error

  defp clickhouse_trace(clickhouse, langfuse, trace_id, {:ok, summary}, max_spans, opts) do
    span_opts = [limit: max_spans] ++ Keyword.take(opts, [:min_duration_ms])

    with {:ok, rows} <- ClickHouse.trace_spans(clickhouse, trace_id, span_opts) do
      started_ms = ClickHouse.number(summary["started_ms"])
      spans = rows |> Enum.map(&clickhouse_span(&1, started_ms)) |> finish_spans()
      span_count = ClickHouse.number(summary["span_count"])
      root = Enum.find(spans, &is_nil(&1.parent_id)) || List.first(spans)

      {:ok,
       %{
         trace_id: trace_id,
         source: :clickhouse,
         name: root && root.name,
         started_at: from_unix_ms(started_ms),
         duration_ms: ClickHouse.number(summary["ended_ms"]) - started_ms,
         span_count: span_count,
         shown_spans: length(spans),
         truncated: span_count > length(spans),
         error: ClickHouse.number(summary["error_count"]) > 0,
         cost_usd: nil,
         langfuse_url: langfuse && Langfuse.trace_url(langfuse, trace_id, langfuse_project_id(langfuse)),
         spans: spans
       }}
    end
  end

  defp clickhouse_span(row, started_ms) do
    attributes = string_map(row["attributes"])

    %{
      id: row["span_id"],
      parent_id: blank_to_nil(row["parent_span_id"]),
      name: row["name"],
      type: row["kind"] |> blank_to_nil() |> downcase(),
      service: blank_to_nil(row["service"]),
      start_offset_ms: ClickHouse.number(row["start_us"]) / 1000 - started_ms,
      duration_ms: ClickHouse.number(row["duration_ns"]) / 1_000_000,
      status: clickhouse_status(row["status_code"]),
      status_message: blank_to_nil(row["status_message"]),
      model: attributes["model"] || attributes["gen_ai.request.model"],
      usage: span_usage(attributes),
      cost_usd: ClickHouse.number_or_nil(attributes["cost_usd"]),
      attributes: attributes
    }
  end

  defp clickhouse_status(code) when code in ["Error", "STATUS_CODE_ERROR"], do: :error
  defp clickhouse_status(code) when code in ["Ok", "STATUS_CODE_OK"], do: :ok
  defp clickhouse_status(_code), do: :unset

  @usage_attributes [
    {"input_tokens", :input},
    {"output_tokens", :output},
    {"cache_read_tokens", :cache_read},
    {"cache_creation_tokens", :cache_creation},
    {"codex.turn.token_usage.non_cached_input_tokens", :input},
    {"codex.turn.token_usage.output_tokens", :output},
    {"codex.turn.token_usage.cached_input_tokens", :cache_read},
    {"codex.turn.token_usage.total_tokens", :total}
  ]

  defp span_usage(attributes) do
    usage =
      for {key, name} <- @usage_attributes, value = ClickHouse.number_or_nil(attributes[key]), into: %{} do
        {name, value}
      end

    if usage == %{}, do: nil, else: usage
  end

  defp langfuse_trace(langfuse, trace, max_spans) do
    observations = trace["observations"] |> List.wrap() |> Enum.filter(&is_map/1)
    trace_start = parse_time(trace["timestamp"])

    starts = observations |> Enum.map(&parse_time(&1["startTime"])) |> Enum.reject(&is_nil/1)
    started_at = Enum.min([trace_start | starts] |> Enum.reject(&is_nil/1), DateTime, fn -> nil end)

    spans =
      observations
      |> Enum.map(&langfuse_span(&1, started_at))
      |> trim(max_spans)
      |> finish_spans()

    %{
      trace_id: trace["id"],
      source: :langfuse,
      name: trace["name"] || (List.first(spans) || %{})[:name],
      started_at: started_at,
      duration_ms: seconds_to_ms(trace["latency"]) || spans_duration(spans),
      span_count: length(observations),
      shown_spans: length(spans),
      truncated: length(observations) > length(spans),
      error: Enum.any?(spans, &(&1.status == :error)),
      cost_usd: ClickHouse.number_or_nil(trace["totalCost"]),
      langfuse_url: Langfuse.html_url(langfuse, trace["htmlPath"]) || Langfuse.trace_url(langfuse, trace["id"], nil),
      spans: spans
    }
  end

  defp langfuse_span(observation, started_at) do
    start = parse_time(observation["startTime"])
    finish = parse_time(observation["endTime"])
    metadata = observation["metadata"]
    attributes = if is_map(metadata) and is_map(metadata["attributes"]), do: metadata["attributes"], else: metadata

    %{
      id: observation["id"],
      parent_id: blank_to_nil(observation["parentObservationId"]),
      name: observation["name"],
      type: observation["type"] |> blank_to_nil() |> downcase(),
      service: find_value(metadata, "service.name"),
      start_offset_ms: diff_ms(start, started_at) || 0,
      duration_ms: diff_ms(finish, start) || seconds_to_ms(observation["latency"]),
      status: langfuse_status(observation["level"]),
      status_message: blank_to_nil(observation["statusMessage"]),
      model: observation["model"],
      usage: langfuse_usage(observation),
      cost_usd:
        ClickHouse.number_or_nil(observation["calculatedTotalCost"]) ||
          ClickHouse.number_or_nil(observation["totalCost"]) ||
          ClickHouse.number_or_nil(get_in_map(observation["costDetails"], "total")),
      attributes: string_map(attributes)
    }
  end

  defp langfuse_status("ERROR"), do: :error
  defp langfuse_status("WARNING"), do: :warning
  defp langfuse_status(_level), do: :unset

  @langfuse_usage_keys %{
    "input" => :input,
    "output" => :output,
    "total" => :total,
    "input_cached_tokens" => :cache_read,
    "cache_read_input_tokens" => :cache_read,
    "cache_creation_input_tokens" => :cache_creation
  }

  defp langfuse_usage(observation) do
    details = if is_map(observation["usageDetails"]), do: observation["usageDetails"], else: %{}
    usage = if is_map(observation["usage"]), do: Map.take(observation["usage"], ["input", "output", "total"]), else: %{}

    result =
      for {key, value} <- Map.merge(usage, details),
          name = @langfuse_usage_keys[key],
          number = ClickHouse.number_or_nil(value),
          number != nil,
          into: %{} do
        {name, number}
      end

    if result == %{}, do: nil, else: result
  end

  # Keep the roots, errors and longest spans when a trace is too big to draw.
  defp trim(spans, max_spans) when length(spans) <= max_spans, do: spans

  defp trim(spans, max_spans) do
    spans
    |> Enum.sort_by(&{&1.parent_id != nil, &1.status != :error, -(&1.duration_ms || 0)})
    |> Enum.take(max_spans)
  end

  # Sorted by start; parents that were cut become nil so the span is drawn at the top level.
  defp finish_spans(spans) do
    ids = MapSet.new(spans, & &1.id)

    spans
    |> Enum.map(fn span -> if MapSet.member?(ids, span.parent_id), do: span, else: %{span | parent_id: nil} end)
    |> Enum.sort_by(&{&1.start_offset_ms, &1.id})
  end

  # The dashboard contract: `id`, `url`, and per span `start_ms`, a string
  # `status` ("ok" | "error") and a one-line `detail`; `otel_status` keeps the
  # finer status (:ok | :error | :warning | :unset).
  defp present_trace(trace) do
    spans =
      Enum.map(trace.spans, fn span ->
        Map.merge(span, %{
          start_ms: span.start_offset_ms,
          status: if(span.status == :error, do: "error", else: "ok"),
          otel_status: span.status,
          detail: span_detail(span)
        })
      end)

    Map.merge(trace, %{id: trace.trace_id, url: trace.langfuse_url, spans: spans})
  end

  defp span_detail(span) do
    usage = span.usage || %{}

    tokens =
      if usage[:input] || usage[:output],
        do: "#{round(usage[:input] || 0)} in / #{round(usage[:output] || 0)} out",
        else: nil

    cost = if is_number(span.cost_usd), do: "$" <> :erlang.float_to_binary(span.cost_usd * 1.0, decimals: 4), else: nil

    case Enum.reject([span.status_message, span.model, tokens, cost], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp spans_duration([]), do: 0

  defp spans_duration(spans) do
    Enum.max(Enum.map(spans, &(&1.start_offset_ms + (&1.duration_ms || 0)))) - Enum.min(Enum.map(spans, & &1.start_offset_ms))
  end

  # ------------------------------------------------------------------ logs

  defp log_event(row) do
    attributes = string_map(row["attributes"])

    %{
      at: from_unix_ms(row["at_ms"]),
      event: row["event"],
      backend: blank_to_nil(row["backend"]),
      trace_id: blank_to_nil(row["trace_id"]),
      severity: blank_to_nil(row["severity"]),
      tool: attributes["tool_name"],
      success: boolean(attributes["success"]),
      duration_ms: ClickHouse.number_or_nil(attributes["duration_ms"]),
      error: attributes["error"] || attributes["error_type"] || attributes["error.message"],
      model: attributes["model"],
      attributes: attributes
    }
  end

  defp boolean("true"), do: true
  defp boolean("false"), do: false
  defp boolean(_value), do: nil

  # ------------------------------------------------------------------ helpers

  defp cached(key, fun), do: Cache.fetch({__MODULE__, key}, Config.observability_cache_ttl_ms(), fun)

  defp clickhouse do
    case Config.observability_clickhouse() do
      nil -> {:error, :not_configured}
      config -> {:ok, config}
    end
  end

  @doc false
  @spec window(range()) :: {:ok, map()} | {:error, :invalid_range}
  def window(range) do
    case range_spec(range) do
      {seconds, bucket} ->
        to_ms = System.os_time(:millisecond)
        {:ok, %{range: range, from_ms: to_ms - seconds * 1000, to_ms: to_ms, bucket: bucket}}

      nil ->
        {:error, :invalid_range}
    end
  end

  defp range_spec(range) when is_map_key(@ranges, range), do: @ranges[range]
  defp range_spec(seconds) when is_integer(seconds) and seconds > 0, do: {seconds, max(div(seconds, 60), 60)}
  defp range_spec(_range), do: nil

  defp identifier(identifier) when is_binary(identifier) do
    case String.trim(identifier) do
      "" -> {:error, :invalid_identifier}
      trimmed when byte_size(trimmed) <= 200 -> {:ok, trimmed}
      _ -> {:error, :invalid_identifier}
    end
  end

  defp identifier(_identifier), do: {:error, :invalid_identifier}

  defp trace_id(trace_id) when is_binary(trace_id) do
    if String.match?(trace_id, ~r/^[A-Za-z0-9_-]{1,128}$/), do: {:ok, trace_id}, else: {:error, :invalid_trace_id}
  end

  defp trace_id(_trace_id), do: {:error, :invalid_trace_id}

  # Langfuse keeps OTel resource and span attributes in (possibly nested) metadata.
  defp names_issue?(metadata, identifier), do: find_value(metadata, "linear.issue.identifier") == identifier

  defp find_value(map, key) when is_map(map) do
    Enum.find_value(map, fn
      {name, value} when is_binary(value) ->
        if name == key or String.ends_with?(to_string(name), "." <> key), do: value

      {_name, value} when is_map(value) ->
        find_value(value, key)

      _ ->
        nil
    end)
  end

  defp find_value(_value, _key), do: nil

  defp get_in_map(map, key) when is_map(map), do: map[key]
  defp get_in_map(_map, _key), do: nil

  defp string_map(map) when is_map(map) do
    map
    |> Enum.take(@attribute_count_limit)
    |> Map.new(fn {key, value} -> {to_string(key), value |> attribute_value() |> String.slice(0, @attribute_value_limit)} end)
  end

  defp string_map(_value), do: %{}

  defp attribute_value(value) when is_binary(value), do: value
  defp attribute_value(value) when is_number(value) or is_boolean(value) or is_atom(value), do: to_string(value)
  defp attribute_value(value), do: Jason.encode!(value)

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp diff_ms(%DateTime{} = later, %DateTime{} = earlier), do: DateTime.diff(later, earlier, :microsecond) / 1000
  defp diff_ms(_later, _earlier), do: nil

  defp seconds_to_ms(value) do
    case ClickHouse.number_or_nil(value) do
      nil -> nil
      seconds -> seconds * 1000
    end
  end

  defp from_unix_ms(value) do
    case DateTime.from_unix(round(ClickHouse.number(value)), :millisecond) do
      {:ok, datetime} -> datetime
      _ -> nil
    end
  end

  defp downcase(nil), do: nil
  defp downcase(value), do: String.downcase(value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
