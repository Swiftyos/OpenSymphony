defmodule SymphonyElixir.Capacity.Metrics do
  @moduledoc """
  In-process counter, gauge and histogram storage for the capacity metrics.

  The table is owned by this process and updated directly by the code being
  measured, so recording a sample costs one ETS operation and never blocks a
  request or a sampler tick.
  """

  use GenServer

  @table :symphony_capacity_metrics

  @histogram_buckets %{
    "symphony_linear_request_duration_seconds" => [
      0.005,
      0.01,
      0.025,
      0.05,
      0.1,
      0.25,
      0.5,
      1.0,
      2.5,
      5.0,
      10.0,
      30.0
    ],
    "symphony_git_operation_duration_seconds" => [
      0.01,
      0.05,
      0.1,
      0.25,
      0.5,
      1.0,
      2.5,
      5.0,
      10.0,
      30.0,
      60.0,
      120.0
    ],
    "symphony_run_memory_bytes_distribution" => [
      0,
      128 * 1024 * 1024,
      256 * 1024 * 1024,
      512 * 1024 * 1024,
      1024 * 1024 * 1024,
      2 * 1024 * 1024 * 1024,
      4 * 1024 * 1024 * 1024,
      8 * 1024 * 1024 * 1024,
      16 * 1024 * 1024 * 1024,
      32 * 1024 * 1024 * 1024
    ],
    "symphony_run_cpu_percent_distribution" => [0, 25, 50, 100, 200, 400, 800]
  }

  @type labels :: keyword(String.t()) | map()
  @type sample :: %{
          name: String.t(),
          labels: labels(),
          value: number()
        }
  @type histogram :: %{
          name: String.t(),
          labels: labels(),
          buckets: [{number() | :inf, non_neg_integer()}],
          count: non_neg_integer(),
          sum: float()
        }
  @type snapshot :: %{
          counters: [sample()],
          gauges: [sample()],
          histograms: [histogram()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  @doc "Adds `amount` to a labelled counter."
  @spec record_counter(String.t(), labels(), number()) :: :ok
  def record_counter(name, labels \\ [], amount \\ 1) when is_binary(name) and is_number(amount) do
    labels = normalize_labels(labels)

    write(fn table ->
      :ets.update_counter(table, {:counter, name, labels}, {2, amount}, {{:counter, name, labels}, 0})
    end)
  end

  @doc "Stores the latest value of a labelled gauge."
  @spec set_gauge(String.t(), labels(), number()) :: :ok
  def set_gauge(name, labels, value) when is_binary(name) and is_number(value) do
    labels = normalize_labels(labels)

    write(fn table ->
      :ets.insert(table, {{:gauge, name, labels}, value})
    end)
  end

  @doc "Deletes every gauge with one of the given names."
  @spec delete_gauges([String.t()]) :: :ok
  def delete_gauges(names) when is_list(names) do
    write(fn table ->
      Enum.each(names, fn name ->
        :ets.match_delete(table, {{:gauge, name, :_}, :_})
      end)
    end)
  end

  @doc "Records one observation in a named histogram."
  @spec record_histogram(String.t(), labels(), number()) :: :ok
  def record_histogram(name, labels, value) when is_binary(name) and is_number(value) do
    labels = normalize_labels(labels)
    buckets = Map.fetch!(@histogram_buckets, name)
    bucket = bucket_index(buckets, value)

    write(fn table ->
      :ets.update_counter(
        table,
        {:histogram, name, labels, {:bucket, bucket}},
        {2, 1},
        {{:histogram, name, labels, {:bucket, bucket}}, 0}
      )

      :ets.update_counter(
        table,
        {:histogram, name, labels, :count},
        {2, 1},
        {{:histogram, name, labels, :count}, 0}
      )

      # update_counter only accepts integers; keep sums in millionths.
      :ets.update_counter(
        table,
        {:histogram, name, labels, :sum},
        {2, round(value * 1_000_000)},
        {{:histogram, name, labels, :sum}, 0}
      )
    end)
  end

  @doc "Returns a consistent-enough point-in-time view of all stored metrics."
  @spec snapshot() :: snapshot()
  def snapshot do
    case table() do
      nil ->
        %{counters: [], gauges: [], histograms: []}

      table ->
        entries = :ets.tab2list(table)

        %{
          counters: samples(entries, :counter),
          gauges: samples(entries, :gauge),
          histograms: histograms(entries)
        }
    end
  end

  @doc "Removes every metric. Used by tests."
  @spec reset() :: :ok
  def reset do
    write(fn table -> :ets.delete_all_objects(table) end)
  end

  @spec histogram_buckets(String.t()) :: [number()]
  def histogram_buckets(name) when is_binary(name), do: Map.fetch!(@histogram_buckets, name)

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

      _table ->
        @table
    end
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined -> nil
      _table -> @table
    end
  end

  @doc false
  @spec write((atom() -> term())) :: :ok
  def write(fun) when is_function(fun, 1) do
    case table() do
      nil ->
        :ok

      table ->
        try do
          fun.(table)
        rescue
          ArgumentError -> :ok
        end
    end

    :ok
  end

  defp samples(entries, kind) do
    for {{^kind, name, labels}, value} <- entries do
      %{name: name, labels: labels, value: value}
    end
  end

  defp histograms(entries) do
    entries
    |> Enum.filter(&match?({{:histogram, _name, _labels, _part}, _value}, &1))
    |> Enum.group_by(fn {{:histogram, name, labels, _part}, _value} -> {name, labels} end)
    |> Enum.map(fn {{name, labels}, group} -> build_histogram(name, labels, group) end)
  end

  defp build_histogram(name, labels, group) do
    bucket_counts = histogram_bucket_counts(group)
    count = histogram_part(group, :count)
    sum = histogram_part(group, :sum) / 1_000_000

    # Derive +Inf from the buckets so a scrape racing the separate count update
    # can never see +Inf below the last bucket.
    inf_count = bucket_counts |> Map.values() |> Enum.sum()

    buckets =
      name
      |> histogram_buckets()
      |> Enum.with_index()
      |> Enum.map(fn {bound, index} -> {bound, cumulative_bucket_count(bucket_counts, index)} end)
      |> Kernel.++([{:inf, inf_count}])

    %{name: name, labels: labels, buckets: buckets, count: count, sum: sum}
  end

  defp histogram_bucket_counts(group) do
    Map.new(group, fn
      {{:histogram, _name, _labels, {:bucket, index}}, value} -> {index, value}
      _other -> {nil, 0}
    end)
    |> Map.delete(nil)
  end

  defp histogram_part(group, part) do
    Enum.find_value(group, 0, fn
      {{:histogram, _name, _labels, ^part}, value} -> value
      _other -> nil
    end)
  end

  defp cumulative_bucket_count(bucket_counts, index) do
    0..index
    |> Enum.map(&Map.get(bucket_counts, &1, 0))
    |> Enum.sum()
  end

  defp bucket_index(buckets, value) do
    case Enum.find_index(buckets, &(value <= &1)) do
      nil -> :inf
      index -> index
    end
  end

  defp normalize_labels(labels) when is_map(labels) do
    labels
    |> Map.to_list()
    |> normalize_labels()
  end

  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
  end
end
