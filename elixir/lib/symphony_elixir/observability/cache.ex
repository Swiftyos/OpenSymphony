defmodule SymphonyElixir.Observability.Cache do
  @moduledoc """
  A small TTL cache (ETS) for dashboard metrics and traces.

  Successful results are kept for `observability.cache_ttl_ms` (30 s by
  default); errors are kept for a few seconds so a source that is down is not
  hammered by every dashboard refresh. Without the owning process (it runs under
  the application supervisor) values are computed and not cached.
  """

  use GenServer

  @table :symphony_observability_cache
  @error_ttl_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    end

    {:ok, %{}}
  end

  @doc """
  The cached value for `key`, or the result of `fun` (cached for `ttl_ms`;
  `{:error, _}` results for at most a few seconds).
  """
  @spec fetch(term(), non_neg_integer(), (-> term())) :: term()
  def fetch(key, ttl_ms, fun) when is_function(fun, 0) do
    now = System.monotonic_time(:millisecond)

    case lookup(key) do
      {:ok, value, expires_at} when expires_at > now -> value
      _ -> compute(key, ttl_ms, now, fun)
    end
  end

  @doc "Drops every cached entry."
  @spec clear() :: :ok
  def clear do
    if table?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  defp compute(key, ttl_ms, now, fun) do
    value = fun.()
    ttl = if match?({:error, _}, value), do: min(ttl_ms, @error_ttl_ms), else: ttl_ms

    if ttl > 0 and table?() do
      :ets.insert(@table, {key, value, now + ttl})
    end

    value
  end

  defp lookup(key) do
    if table?() do
      case :ets.lookup(@table, key) do
        [{^key, value, expires_at}] -> {:ok, value, expires_at}
        [] -> :miss
      end
    else
      :miss
    end
  end

  defp table?, do: :ets.whereis(@table) != :undefined
end
