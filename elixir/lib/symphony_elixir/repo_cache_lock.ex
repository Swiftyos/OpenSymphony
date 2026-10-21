defmodule SymphonyElixir.RepoCacheLock do
  @moduledoc """
  Serializes repo cache syncs per cache path on this host.

  `:global.trans/4` does not provide local mutual exclusion on a non-distributed
  node (the default for Symphony), so this GenServer owns the locks instead. It
  monitors holders and waiters: a crashed process releases its lock and is
  dropped from the wait queue.
  """

  use GenServer

  @type key :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{owners: %{}, waiters: %{}}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs `fun` while holding the lock for `key`."
  @spec with_lock(key(), (-> result)) :: result when result: var
  def with_lock(key, fun) when is_function(fun, 0) do
    :ok = GenServer.call(__MODULE__, {:acquire, key}, :infinity)

    try do
      fun.()
    after
      GenServer.cast(__MODULE__, {:release, key})
    end
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, key}, {pid, _reference} = from, state) do
    monitor_ref = Process.monitor(pid)

    if Map.has_key?(state.owners, key) do
      waiters =
        Map.update(
          state.waiters,
          key,
          :queue.from_list([{from, monitor_ref}]),
          &:queue.in({from, monitor_ref}, &1)
        )

      {:noreply, %{state | waiters: waiters}}
    else
      {:reply, :ok, %{state | owners: Map.put(state.owners, key, {pid, monitor_ref})}}
    end
  end

  @impl true
  def handle_cast({:release, key}, state) do
    {:noreply, release(key, state)}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    {:noreply, state |> drop_owner(monitor_ref) |> drop_waiter(monitor_ref)}
  end

  defp release(key, state) do
    state = %{state | owners: Map.delete(state.owners, key)}

    case pop_waiter(state.waiters, key) do
      {:ok, {from, monitor_ref}, waiters} ->
        GenServer.reply(from, :ok)

        %{
          state
          | owners: Map.put(state.owners, key, {elem(from, 0), monitor_ref}),
            waiters: waiters
        }

      :empty ->
        %{state | waiters: Map.delete(state.waiters, key)}
    end
  end

  defp pop_waiter(waiters, key) do
    case :queue.out(Map.get(waiters, key, :queue.new())) do
      {{:value, waiter}, remaining} ->
        waiters =
          if :queue.is_empty(remaining),
            do: Map.delete(waiters, key),
            else: Map.put(waiters, key, remaining)

        {:ok, waiter, waiters}

      {:empty, _queue} ->
        :empty
    end
  end

  defp drop_owner(state, monitor_ref) do
    case Enum.find(state.owners, fn {_key, {_pid, ref}} -> ref == monitor_ref end) do
      {key, _owner} -> release(key, state)
      nil -> state
    end
  end

  defp drop_waiter(state, monitor_ref) do
    waiters =
      state.waiters
      |> Enum.map(fn {key, queue} ->
        {key, :queue.filter(fn {_from, ref} -> ref != monitor_ref end, queue)}
      end)
      |> Enum.reject(fn {_key, queue} -> :queue.is_empty(queue) end)
      |> Map.new()

    %{state | waiters: waiters}
  end
end
