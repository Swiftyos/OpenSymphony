defmodule SymphonyElixir.RunWatcher.LastSeen do
  @moduledoc """
  When each watched run was last heard from, in a public ETS table.

  Every runner event touches its run, and the orchestrator reads every run's
  last-seen time on each poll for stall detection. Kept here instead of in
  each `SymphonyElixir.RunWatcher`'s state, a touch is one ETS write in the
  request process and a read is one lookup: no message to the watcher per
  event and no serial calls from the orchestrator.

  Rows are `{run_id, watcher_pid, unix_ms}`; a read for another watcher's pid
  (an earlier watcher of the same run) is nil. A watcher writes its row when it
  starts and deletes it when it stops. Without this process (a runner, a bare
  test) every function returns `:unavailable` and watchers keep the time
  themselves.
  """

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Records that `run_id`, watched by `watcher`, was seen at `unix_ms`."
  @spec put(String.t(), pid(), integer()) :: :ok | :unavailable
  def put(run_id, watcher, unix_ms) when is_binary(run_id) and is_pid(watcher) and is_integer(unix_ms) do
    :ets.insert(@table, {run_id, watcher, unix_ms})
    :ok
  rescue
    ArgumentError -> :unavailable
  end

  @doc "When `run_id` was last seen by `watcher`: unix ms, nil, or `:unavailable`."
  @spec get(String.t(), pid()) :: integer() | nil | :unavailable
  def get(run_id, watcher) when is_binary(run_id) and is_pid(watcher) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, ^watcher, unix_ms}] -> unix_ms
      _none_or_other_watcher -> nil
    end
  rescue
    ArgumentError -> :unavailable
  end

  @doc "Forgets `run_id` if `watcher` still owns its row."
  @spec delete(String.t(), pid()) :: :ok
  def delete(run_id, watcher) when is_binary(run_id) and is_pid(watcher) do
    :ets.match_delete(@table, {run_id, watcher, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    {:ok, nil}
  end
end
