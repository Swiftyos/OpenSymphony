defmodule SymphonyElixir.GitHubApp.Cache do
  @moduledoc """
  Per-repository cache for GitHub App installation tokens.

  The ETS table belongs to this process. A miss starts one fetch per key; other
  callers for the same key wait for that result instead of minting their own
  token. Each caller says how long an entry must still be valid for it
  (`min_ttl_ms`, five minutes by default); an entry closer to expiry is
  replaced by a fresh fetch.
  """

  use GenServer

  @default_min_ttl_ms 5 * 60 * 1000

  @type entry :: %{token: String.t(), expires_at: DateTime.t()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Returns a cached entry, or calls `fetch_fun` once for all concurrent callers.

  `clock` returns the current `DateTime`. `fetch_fun` returns
  `{:ok, %{token: token, expires_at: DateTime.t()}}` or an error. A cached entry
  is returned only while it has more than `min_ttl_ms` left.
  """
  @spec fetch(GenServer.server(), term(), (-> DateTime.t()), (-> term()), non_neg_integer()) :: term()
  def fetch(server \\ __MODULE__, key, clock, fetch_fun, min_ttl_ms \\ @default_min_ttl_ms)
      when is_function(clock, 0) and is_function(fetch_fun, 0) and is_integer(min_ttl_ms) and min_ttl_ms >= 0 do
    GenServer.call(server, {:fetch, key, clock, fetch_fun, min_ttl_ms}, :infinity)
  end

  @doc "The `min_ttl_ms` used when a caller does not pass one."
  @spec default_min_ttl_ms() :: non_neg_integer()
  def default_min_ttl_ms, do: @default_min_ttl_ms

  @impl true
  def init(_opts) do
    {:ok, %{table: :ets.new(__MODULE__, [:set, :private]), pending: %{}}}
  end

  @impl true
  def handle_call({:fetch, key, clock, fetch_fun, min_ttl_ms}, from, state) do
    now_ms = DateTime.to_unix(clock.(), :millisecond)

    case fresh_entry(state.table, key, now_ms, min_ttl_ms) do
      {:ok, entry} ->
        {:reply, {:ok, entry}, state}

      :miss ->
        {:noreply, start_or_join_fetch(state, key, from, fetch_fun)}
    end
  end

  defp start_or_join_fetch(state, key, from, fetch_fun) do
    case Map.fetch(state.pending, key) do
      {:ok, pending} ->
        put_in(state.pending[key], %{pending | waiters: [from | pending.waiters]})

      :error ->
        server = self()
        {pid, monitor} = spawn_monitor(fn -> send(server, {:fetched, key, self(), safe_fetch(fetch_fun)}) end)

        put_in(state.pending[key], %{pid: pid, monitor: monitor, waiters: [from]})
    end
  end

  @impl true
  def handle_info({:fetched, key, pid, result}, state) do
    case Map.fetch(state.pending, key) do
      {:ok, %{pid: ^pid} = pending} ->
        Process.demonitor(pending.monitor, [:flush])
        cache_result(state.table, key, result)
        Enum.each(pending.waiters, &GenServer.reply(&1, reply(result)))
        {:noreply, %{state | pending: Map.delete(state.pending, key)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _monitor, :process, pid, reason}, state) do
    case Enum.find(state.pending, fn {_key, pending} -> pending.pid == pid end) do
      {key, pending} ->
        Enum.each(pending.waiters, &GenServer.reply(&1, {:error, {:fetch_failed, reason}}))
        {:noreply, %{state | pending: Map.delete(state.pending, key)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp fresh_entry(table, key, now_ms, min_ttl_ms) do
    case :ets.lookup(table, key) do
      [{^key, %{expires_at: %DateTime{} = expires_at} = entry}] ->
        if DateTime.to_unix(expires_at, :millisecond) - now_ms > min_ttl_ms, do: {:ok, entry}, else: :miss

      _ ->
        :miss
    end
  end

  defp cache_result(table, key, {:ok, %{token: token, expires_at: %DateTime{} = expires_at}}) do
    :ets.insert(table, {key, %{token: token, expires_at: expires_at}})
  end

  defp cache_result(_table, _key, _result), do: :ok

  defp reply({:ok, %{token: token, expires_at: expires_at}}), do: {:ok, %{token: token, expires_at: expires_at}}
  defp reply({:error, _reason} = error), do: error
  defp reply(other), do: {:error, {:invalid_token_response, other}}

  defp safe_fetch(fetch_fun) do
    fetch_fun.()
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
