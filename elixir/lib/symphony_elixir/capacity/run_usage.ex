defmodule SymphonyElixir.Capacity.RunUsage do
  @moduledoc """
  The latest CPU and memory each runner reported about itself, by issue.

  Runners (pods, process runners) send `metrics` events over `/runner/v1`
  (`SymphonyElixir.Capacity.UsageReporter`); `SymphonyElixirWeb.RunnerController`
  stores them here, and `SymphonyElixir.Capacity.Sampler` turns them into the
  same per-run series it measures for local runs, so dashboards work for both.

  Every runner event also marks its issue as runner-hosted (`mark_remote/1`):
  the agent pid a runner reports belongs to its own host (a pod), so the
  sampler must never match it against the controller's `ps`. Rows for issues
  no longer running are pruned by the sampler each tick.
  """

  use GenServer

  alias SymphonyElixir.Capacity.Metrics

  @table :symphony_run_usage

  @type sample :: %{cpu_percent: float() | nil, memory_bytes: non_neg_integer(), source: String.t()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    end

    {:ok, %{}}
  end

  @doc "Marks the issue's run as hosted by a runner, not by the controller."
  @spec mark_remote(String.t() | nil) :: :ok
  def mark_remote(issue_id) when is_binary(issue_id) do
    write(fn table ->
      now = now_ms()
      :ets.update_element(table, issue_id, {2, now}) or :ets.insert_new(table, {issue_id, now, nil, nil})
    end)
  end

  def mark_remote(_issue_id), do: :ok

  @doc """
  Stores a runner's `metrics` event (`cpu_percent`, `memory_bytes`,
  `source`) for the issue; anything without a memory figure is ignored.
  """
  @spec report(String.t() | nil, map()) :: :ok
  def report(issue_id, data) when is_binary(issue_id) and is_map(data) do
    case value(data, :memory_bytes) do
      bytes when is_integer(bytes) and bytes >= 0 ->
        source = source_label(value(data, :source))
        sample = %{cpu_percent: cpu_percent(value(data, :cpu_percent)), memory_bytes: bytes, source: source}
        now = now_ms()
        write(fn table -> :ets.insert(table, {issue_id, now, now, sample}) end)
        Metrics.record_counter("symphony_run_usage_reports_total", source: source)

      _invalid ->
        :ok
    end
  end

  def report(_issue_id, _data), do: :ok

  @doc """
  The issue's latest report when it is younger than `max_age_ms`, `:remote`
  for a runner-hosted run without a fresh one, or `:none`.
  """
  @spec fetch(String.t() | nil, non_neg_integer()) :: {:ok, sample()} | :remote | :none
  def fetch(issue_id, max_age_ms) when is_binary(issue_id) do
    case safe_lookup(issue_id) do
      [{^issue_id, _seen, reported, sample}] when is_integer(reported) and is_map(sample) ->
        if now_ms() - reported <= max_age_ms, do: {:ok, sample}, else: :remote

      [{^issue_id, _seen, _reported, _sample}] ->
        :remote

      [] ->
        :none
    end
  end

  def fetch(_issue_id, _max_age_ms), do: :none

  @doc "Drops every row whose issue is not in `issue_ids` (the running issues)."
  @spec prune(Enumerable.t()) :: :ok
  def prune(issue_ids) do
    keep = MapSet.new(issue_ids)

    write(fn table ->
      for {issue_id, _seen, _reported, _sample} <- :ets.tab2list(table), not MapSet.member?(keep, issue_id) do
        :ets.delete(table, issue_id)
      end
    end)
  end

  @doc false
  @spec reset() :: :ok
  def reset, do: write(&:ets.delete_all_objects/1)

  # Bounded label: the three sources SelfUsage knows, else "other".
  defp source_label(source) when source in ["cgroup_v2", "cgroup_v1", "proc"], do: source
  defp source_label(_source), do: "other"

  defp cpu_percent(value) when is_number(value) and value >= 0, do: value * 1.0
  defp cpu_percent(_value), do: nil

  defp value(data, key), do: Map.get(data, key) || Map.get(data, Atom.to_string(key))

  # The table belongs to this module's process, which runs for the whole
  # controller; before it starts (or in a runner) there is nothing to record.
  defp write(fun) do
    if :ets.whereis(@table) != :undefined, do: fun.(@table)
    :ok
  end

  defp safe_lookup(key), do: if(:ets.whereis(@table) == :undefined, do: [], else: :ets.lookup(@table, key))

  defp now_ms, do: System.monotonic_time(:millisecond)
end
