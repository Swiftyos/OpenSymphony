defmodule SymphonyElixir.GitMirror.Limiter do
  @moduledoc """
  Caps how many `git upload-pack` processes the read-only mirror runs at once.

  A request takes a slot before it starts git and gives it back when git is
  done. The limiter monitors each holder, so a request process that crashes
  or is killed on client disconnect frees its slot without an explicit
  release. The cap is passed on every acquire, so a config reload applies to
  the next request.
  """

  use GenServer

  @type slot :: reference()

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Takes a slot for the calling process, or `:full` when `max` are held."
  @spec acquire(pos_integer(), GenServer.server()) :: {:ok, slot()} | :full
  def acquire(max, server \\ __MODULE__) when is_integer(max) and max > 0 do
    GenServer.call(server, {:acquire, self(), max})
  end

  @doc "Gives a slot back; releasing an unknown slot is a no-op."
  @spec release(slot(), GenServer.server()) :: :ok
  def release(slot, server \\ __MODULE__) when is_reference(slot) do
    GenServer.call(server, {:release, slot})
  end

  @doc "How many slots are held."
  @spec in_use(GenServer.server()) :: non_neg_integer()
  def in_use(server \\ __MODULE__), do: GenServer.call(server, :in_use)

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:acquire, pid, max}, _from, holders) when map_size(holders) < max do
    slot = Process.monitor(pid)
    {:reply, {:ok, slot}, Map.put(holders, slot, pid)}
  end

  def handle_call({:acquire, _pid, _max}, _from, holders), do: {:reply, :full, holders}

  def handle_call({:release, slot}, _from, holders) do
    Process.demonitor(slot, [:flush])
    {:reply, :ok, Map.delete(holders, slot)}
  end

  def handle_call(:in_use, _from, holders), do: {:reply, map_size(holders), holders}

  @impl true
  def handle_info({:DOWN, slot, :process, _pid, _reason}, holders), do: {:noreply, Map.delete(holders, slot)}
end
