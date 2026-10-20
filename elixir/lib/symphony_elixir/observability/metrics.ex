defmodule SymphonyElixir.Observability.Metrics do
  @moduledoc """
  Turns ClickHouse fact rows (see `SymphonyElixir.Observability.ClickHouse.facts/4`)
  into the totals, breakdowns and chart series served by
  `SymphonyElixir.Observability`. Pure functions.

  Codex reports no cost, so groups without a `cost_usd` fact are priced from
  their tokens with `SymphonyElixir.Pricing` (`pricing` in the config) and the
  result is reported both inside `cost_usd` and separately as
  `estimated_cost_usd`.
  """

  alias SymphonyElixir.Observability.ClickHouse
  alias SymphonyElixir.Pricing

  @type totals :: %{
          tokens: number(),
          input_tokens: number(),
          output_tokens: number(),
          cache_read_tokens: number(),
          cache_creation_tokens: number(),
          cost_usd: float(),
          estimated_cost_usd: float(),
          tool_calls: number(),
          tool_errors: number(),
          turns: number(),
          api_requests: number(),
          api_errors: number(),
          lines_added: number(),
          lines_removed: number(),
          commits: number(),
          active_seconds: number()
        }

  @token_measures %{
    "tokens_input" => :input_tokens,
    "tokens_output" => :output_tokens,
    "tokens_cache_read" => :cache_read_tokens,
    "tokens_cache_creation" => :cache_creation_tokens
  }
  @counter_measures %{
    "tool_calls" => :tool_calls,
    "tool_errors" => :tool_errors,
    "turns" => :turns,
    "api_requests" => :api_requests,
    "api_errors" => :api_errors,
    "lines_added" => :lines_added,
    "lines_removed" => :lines_removed,
    "commits" => :commits,
    "active_seconds" => :active_seconds
  }

  @doc "Totals with every counter at zero."
  @spec empty_totals() :: totals()
  def empty_totals do
    %{
      tokens: 0,
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      cost_usd: 0.0,
      estimated_cost_usd: 0.0,
      tool_calls: 0,
      tool_errors: 0,
      turns: 0,
      api_requests: 0,
      api_errors: 0,
      lines_added: 0,
      lines_removed: 0,
      commits: 0,
      active_seconds: 0
    }
  end

  @doc """
  Normalizes raw rows (numeric `value`) and adds an `estimated_cost_usd` row to
  every group (same dims) that has tokens but no `cost_usd`, when a price is
  configured for its backend and model.
  """
  @spec prepare([map()], map() | nil) :: [map()]
  def prepare(rows, pricing \\ nil) do
    rows = Enum.map(rows, &Map.update(&1, "value", 0, fn value -> ClickHouse.number(value) end))

    estimates =
      rows
      |> Enum.group_by(&Map.drop(&1, ["measure", "value"]))
      |> Enum.flat_map(fn {dims, group} -> estimate(dims, group, pricing) end)

    rows ++ estimates
  end

  defp estimate(dims, group, pricing) do
    values = Map.new(group, &{&1["measure"], &1["value"]})

    if Map.has_key?(values, "cost_usd") do
      []
    else
      input = Map.get(values, "tokens_input", 0)
      cached = Map.get(values, "tokens_cache_read", 0)
      output = Map.get(values, "tokens_output", 0)
      delta = %{input_tokens: round(input + cached), cached_input_tokens: round(cached), output_tokens: round(output)}

      case Pricing.cost_micros(dims["backend"], blank_to_nil(dims["model"]), delta, DateTime.utc_now(), pricing) do
        micros when is_integer(micros) and micros > 0 ->
          [Map.merge(dims, %{"measure" => "estimated_cost_usd", "value" => micros / 1_000_000})]

        _ ->
          []
      end
    end
  end

  @doc "Sums rows into one totals map."
  @spec totals([map()]) :: totals()
  def totals(rows), do: Enum.reduce(rows, empty_totals(), &add/2)

  defp add(%{"measure" => measure, "value" => value}, totals) do
    cond do
      key = @token_measures[measure] ->
        %{Map.update!(totals, key, &(&1 + value)) | tokens: totals.tokens + value}

      key = @counter_measures[measure] ->
        Map.update!(totals, key, &(&1 + value))

      measure == "cost_usd" ->
        %{totals | cost_usd: totals.cost_usd + value}

      measure == "estimated_cost_usd" ->
        %{totals | cost_usd: totals.cost_usd + value, estimated_cost_usd: totals.estimated_cost_usd + value}

      true ->
        totals
    end
  end

  defp add(_row, totals), do: totals

  @doc "Totals per value of the `dim` column (blank values are skipped)."
  @spec totals_by([map()], String.t()) :: %{String.t() => totals()}
  def totals_by(rows, dim) do
    rows
    |> Enum.reject(&(blank_to_nil(&1[dim]) == nil))
    |> Enum.group_by(& &1[dim])
    |> Map.new(fn {key, group} -> {key, totals(group)} end)
  end

  @doc "Token and cost totals per backend and model, most expensive first."
  @spec by_model([map()]) :: [map()]
  def by_model(rows) do
    rows
    |> Enum.filter(&(blank_to_nil(&1["model"]) != nil))
    |> Enum.group_by(&{&1["backend"], &1["model"]})
    |> Enum.map(fn {{backend, model}, group} ->
      totals = totals(group)

      totals
      |> Map.take([:tokens, :input_tokens, :output_tokens, :cache_read_tokens, :cache_creation_tokens, :cost_usd, :api_requests])
      |> Map.merge(%{backend: backend, model: model})
    end)
    |> Enum.sort_by(&{-&1.cost_usd, -&1.tokens})
  end

  @doc "The `limit` issues with the highest cost (then tokens)."
  @spec top_issues([map()], pos_integer()) :: [map()]
  def top_issues(rows, limit) do
    rows
    |> Enum.filter(&(blank_to_nil(&1["issue"]) != nil))
    |> Enum.group_by(& &1["issue"])
    |> Enum.map(fn {issue, group} ->
      totals = totals(group)

      %{
        identifier: issue,
        title: nil,
        backends: group |> Enum.map(& &1["backend"]) |> Enum.uniq() |> Enum.sort(),
        tokens: totals.tokens,
        cost_usd: totals.cost_usd,
        tool_calls: totals.tool_calls,
        turns: totals.turns
      }
    end)
    |> Enum.sort_by(&{-&1.cost_usd, -&1.tokens})
    |> Enum.take(limit)
  end

  @doc "The `limit` most-called tools: `%{name, backend, calls, errors}`."
  @spec top_tools([map()], pos_integer()) :: [map()]
  def top_tools(rows, limit) do
    rows
    |> Enum.filter(&(blank_to_nil(&1["tool"]) != nil))
    |> Enum.group_by(&{&1["backend"], &1["tool"]})
    |> Enum.map(fn {{backend, tool}, group} ->
      totals = totals(group)
      %{name: tool, backend: backend, calls: totals.tool_calls, errors: totals.tool_errors}
    end)
    |> Enum.sort_by(&{-&1.calls, &1.name})
    |> Enum.take(limit)
  end

  @doc """
  Chart series from `bucket`-dimensioned rows: `%{tokens: points, cost: points,
  tool_calls: points}`, one point per bucket from `from_s` to `to_s` (unix
  seconds), oldest first, `%{at: DateTime, values: %{backend => number}}`. Every
  backend in `backends` (plus any seen in the rows) is present in every point,
  zero-filled.
  """
  @spec series([map()], integer(), integer(), pos_integer(), [String.t()]) :: %{atom() => [map()]}
  def series(rows, from_s, to_s, bucket, backends) do
    by_bucket = Enum.group_by(rows, &ClickHouse.number(&1["bucket"]))
    backends = (backends ++ Enum.map(rows, & &1["backend"])) |> Enum.reject(&(blank_to_nil(&1) == nil)) |> Enum.uniq()
    zero = Map.new(backends, &{&1, 0})
    first = div(from_s, bucket) * bucket

    points =
      first
      |> Stream.iterate(&(&1 + bucket))
      |> Enum.take_while(&(&1 <= to_s))
      |> Enum.map(fn at ->
        by_backend =
          by_bucket
          |> Map.get(at, [])
          |> Enum.group_by(& &1["backend"])
          |> Map.new(fn {backend, group} -> {backend, totals(group)} end)

        {DateTime.from_unix!(at), by_backend}
      end)

    %{
      tokens: points_for(points, zero, & &1.tokens),
      cost: points_for(points, zero, & &1.cost_usd),
      tool_calls: points_for(points, zero, & &1.tool_calls)
    }
  end

  defp points_for(points, zero, value) do
    Enum.map(points, fn {at, by_backend} ->
      %{at: at, values: Enum.reduce(by_backend, zero, fn {backend, totals}, acc -> Map.put(acc, backend, value.(totals)) end)}
    end)
  end

  @doc """
  Latency percentiles per backend from `ClickHouse.latency/3` rows:
  `%{backend => %{p50: ms | nil, p95: ms | nil, count: n}}`.
  """
  @spec latency([map()]) :: %{String.t() => %{p50: number() | nil, p95: number() | nil, count: number()}}
  def latency(rows) do
    rows
    |> Enum.group_by(& &1["backend"])
    |> Map.new(fn {backend, group} -> {backend, backend_latency(group)} end)
  end

  @doc """
  One p50/p95 across backends: the request-weighted mean of each backend's
  percentile (an approximation; per-backend values are exact or bucket-interpolated).
  """
  @spec overall_latency(%{String.t() => map()}) :: %{p50: float() | nil, p95: float() | nil}
  def overall_latency(by_backend) do
    %{p50: weighted(by_backend, :p50), p95: weighted(by_backend, :p95)}
  end

  defp weighted(by_backend, key) do
    entries =
      for {_backend, %{^key => value, count: count}} <- by_backend, is_number(value) and count > 0 do
        {value, count}
      end

    case Enum.sum(Enum.map(entries, &elem(&1, 1))) do
      0 -> nil
      total -> Float.round(Enum.sum(Enum.map(entries, fn {value, count} -> value * count end)) / total, 1)
    end
  end

  defp backend_latency(rows) do
    case Enum.find(rows, &(&1["kind"] == "quantiles")) do
      %{} = row ->
        %{p50: round_ms(row["p50"]), p95: round_ms(row["p95"]), count: row["count"]}

      nil ->
        # Several bound sets can only be merged approximately; take the busiest.
        %{"bounds" => bounds, "counts" => counts} =
          Enum.max_by(rows, fn row -> row["counts"] |> List.wrap() |> Enum.map(&ClickHouse.number/1) |> Enum.sum() end)

        bounds = Enum.map(bounds, &ClickHouse.number/1)
        counts = Enum.map(counts, &ClickHouse.number/1)

        %{
          p50: round_ms(histogram_quantile(bounds, counts, 0.5)),
          p95: round_ms(histogram_quantile(bounds, counts, 0.95)),
          count: Enum.sum(counts)
        }
    end
  end

  @doc """
  Estimates the `q` quantile of an explicit-bounds histogram (OTel layout: one
  more count than bounds) by linear interpolation inside the bucket. Values in
  the overflow bucket report the last bound. Nil when the histogram is empty.
  """
  @spec histogram_quantile([number()], [number()], float()) :: float() | nil
  def histogram_quantile(bounds, counts, q) do
    total = Enum.sum(counts)

    if total <= 0 do
      nil
    else
      target = q * total
      lowers = [0 | bounds]
      uppers = bounds ++ [List.last(bounds) || 0]

      # Some bucket with a count always reaches the target, since 0 <= q <= 1.
      [lowers, uppers, counts]
      |> Enum.zip()
      |> Enum.reduce_while(0, &quantile_step(&1, &2, target))
    end
  end

  defp quantile_step({lower, upper, count}, seen, target) when count > 0 and seen + count >= target do
    {:halt, (lower + (upper - lower) * (target - seen) / count) * 1.0}
  end

  defp quantile_step({_lower, _upper, count}, seen, _target), do: {:cont, seen + count}

  defp round_ms(value) when is_number(value), do: Float.round(value * 1.0, 1)
  defp round_ms(_value), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
