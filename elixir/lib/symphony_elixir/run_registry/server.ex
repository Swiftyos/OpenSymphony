defmodule SymphonyElixir.RunRegistry.Server do
  @moduledoc """
  The single writer of the run registry, and its in-memory cache.

  The orchestrator records and deletes runs while the runner endpoints advance
  their event progress. Each of those changes one issue's document, and they
  are applied here one at a time: none is lost, and a progress write can't
  bring back a run that was just deleted.

  The decoded registry is kept in a protected ETS table, loaded from the
  store the first time a registry path is used, with one row per issue
  (`{{:issue, path, issue_id}, epoch, entry | nil}`) and an index by run id
  (`{{:run, path, run_id}, issue_id}`). Readers (`lookup/2`, `find_run/2`,
  `docs/1`) read the table directly, without a call, so a runner request
  costs one ETS lookup however many runs there are.

  Progress without a finished reason updates the table at once and is
  persisted at most once per `flush_interval_ms` (1s by default), only for the
  issues that changed, or with the next synchronous write to the same issue.
  A finished reason, a record and a delete are written before the call
  returns. Pending progress is written on shutdown.

  The public API is `SymphonyElixir.RunRegistry`; when this server isn't
  running (a runner, or a bare test) its writes are applied in the caller and
  reads go to the store.
  """

  use GenServer

  alias SymphonyElixir.RunRegistry

  @flush_interval_ms 1_000
  @table __MODULE__

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Applies a write to the registry at `path` (with any progress pending for
  the issue). Returns false when the server isn't running, so the caller
  applies it.
  """
  @spec write(Path.t(), tuple()) :: boolean()
  def write(path, op), do: call({:write, path, op}, false)

  @doc "Applies a run's progress to the cache for the next coalesced write; false without the server."
  @spec buffer_progress(Path.t(), String.t(), String.t(), non_neg_integer()) :: boolean()
  def buffer_progress(path, issue_id, run_id, last_seq), do: call({:progress, path, issue_id, run_id, last_seq}, false)

  @doc "Progress applied for `path` and not yet written, by issue id."
  @spec pending(Path.t()) :: %{String.t() => {String.t(), non_neg_integer()}}
  def pending(path), do: call({:pending, path}, %{})

  @doc "Writes all buffered progress now."
  @spec flush() :: :ok
  def flush, do: call(:flush, :ok)

  @doc "Forgets the cache for `path` (after writing its pending progress)."
  @spec drop(Path.t()) :: :ok
  def drop(path), do: call({:drop, path}, :ok)

  @doc "The cached document of `issue_id`, nil when there is none, or `:unavailable` without the server."
  @spec lookup(Path.t(), String.t()) :: RunRegistry.doc() | nil | :unavailable
  def lookup(path, issue_id) do
    with :ok <- ensure_loaded(path) do
      case safe_lookup({:issue, path, issue_id}) do
        [{_key, epoch, run}] -> %{epoch: epoch, run: run}
        [] -> nil
        :unavailable -> :unavailable
      end
    end
  end

  @doc "The cached run with `run_id` as `{issue_id, entry}`, nil, or `:unavailable` without the server."
  @spec find_run(Path.t(), String.t()) :: {String.t(), RunRegistry.entry()} | nil | :unavailable
  def find_run(path, run_id) do
    with :ok <- ensure_loaded(path) do
      case safe_lookup({:run, path, run_id}) do
        [{_key, issue_id}] -> run_for(path, issue_id, run_id)
        [] -> nil
        :unavailable -> :unavailable
      end
    end
  end

  defp run_for(path, issue_id, run_id) do
    case safe_lookup({:issue, path, issue_id}) do
      [{_key, _epoch, %{run_id: ^run_id} = entry}] -> {issue_id, entry}
      [] -> nil
      :unavailable -> :unavailable
      _other_run -> nil
    end
  end

  @doc "Every cached issue document for `path`, or `:unavailable` without the server."
  @spec docs(Path.t()) :: %{String.t() => RunRegistry.doc()} | :unavailable
  def docs(path) do
    with :ok <- ensure_loaded(path) do
      try do
        @table
        |> :ets.match({{:issue, path, :"$1"}, :"$2", :"$3"})
        |> Map.new(fn [issue_id, epoch, run] -> {issue_id, %{epoch: epoch, run: run}} end)
      rescue
        ArgumentError -> :unavailable
      end
    end
  end

  defp ensure_loaded(path) do
    case safe_lookup({:loaded, path}) do
      [_loaded] -> :ok
      [] -> call({:load, path}, :unavailable)
      :unavailable -> :unavailable
    end
  end

  defp safe_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> :unavailable
  end

  defp call(message, fallback) do
    case Process.whereis(__MODULE__) do
      nil ->
        fallback

      pid ->
        try do
          GenServer.call(pid, message, :infinity)
        catch
          :exit, _reason -> fallback
        end
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{dirty: %{}, timer: nil, flush_interval_ms: Keyword.get(opts, :flush_interval_ms, @flush_interval_ms)}}
  end

  @impl true
  def handle_call({:load, path}, _from, state) do
    load(path)
    {:reply, :ok, state}
  end

  def handle_call({:write, path, op}, _from, state) do
    load(path)
    issue_id = elem(op, 1)
    {docs, changed} = RunRegistry.apply_op(op, cached(path, issue_id))
    put_cached(path, docs)

    # The issue's pending progress is in its document, so it is written too.
    {was_dirty, state} = take_dirty(state, path, issue_id)
    :ok = RunRegistry.persist(path, docs, Enum.uniq(changed ++ was_dirty))
    {:reply, true, state}
  end

  def handle_call({:progress, path, issue_id, run_id, last_seq}, _from, state) do
    load(path)
    {docs, changed} = RunRegistry.apply_op({:progress, issue_id, run_id, last_seq, nil}, cached(path, issue_id))

    state =
      case changed do
        [] ->
          state

        _changed ->
          put_cached(path, docs)
          dirty = Map.update(state.dirty, path, MapSet.new(changed), &MapSet.union(&1, MapSet.new(changed)))
          schedule_flush(%{state | dirty: dirty})
      end

    {:reply, true, state}
  end

  def handle_call({:pending, path}, _from, state) do
    pending =
      for issue_id <- Map.get(state.dirty, path, MapSet.new()),
          %{run: %{run_id: run_id, last_seq: seq}} <- [Map.get(cached(path, issue_id), issue_id)],
          into: %{},
          do: {issue_id, {run_id, seq}}

    {:reply, pending, state}
  end

  def handle_call(:flush, _from, state), do: {:reply, :ok, flush_all(state)}

  def handle_call({:drop, path}, _from, state) do
    state = flush_path(state, path)
    :ets.match_delete(@table, {{:issue, path, :_}, :_, :_})
    :ets.match_delete(@table, {{:run, path, :_}, :_})
    :ets.delete(@table, {:loaded, path})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush_all(%{state | timer: nil})}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    flush_all(state)
    :ok
  end

  defp load(path) do
    if :ets.member(@table, {:loaded, path}) do
      :ok
    else
      path |> RunRegistry.read_store() |> then(&put_cached(path, &1))
      :ets.insert(@table, {{:loaded, path}})
      :ok
    end
  end

  defp cached(path, issue_id) do
    case :ets.lookup(@table, {:issue, path, issue_id}) do
      [{_key, epoch, run}] -> %{issue_id => %{epoch: epoch, run: run}}
      [] -> %{}
    end
  end

  defp put_cached(path, docs) do
    Enum.each(docs, fn {issue_id, %{epoch: epoch, run: run}} ->
      # The index row of a run this issue no longer has goes first.
      new_run_id = run && run.run_id

      case :ets.lookup(@table, {:issue, path, issue_id}) do
        [{_key, _epoch, %{run_id: old_run_id}}] when old_run_id != new_run_id ->
          :ets.delete(@table, {:run, path, old_run_id})

        _same_or_none ->
          :ok
      end

      :ets.insert(@table, {{:issue, path, issue_id}, epoch, run})
      if run, do: :ets.insert(@table, {{:run, path, run.run_id}, issue_id})
    end)
  end

  defp schedule_flush(%{timer: nil} = state) do
    %{state | timer: Process.send_after(self(), :flush, state.flush_interval_ms)}
  end

  defp schedule_flush(state), do: state

  defp take_dirty(state, path, issue_id) do
    issues = Map.get(state.dirty, path, MapSet.new())

    if MapSet.member?(issues, issue_id) do
      {[issue_id], %{state | dirty: Map.put(state.dirty, path, MapSet.delete(issues, issue_id))}}
    else
      {[], state}
    end
  end

  defp flush_all(state), do: Enum.reduce(Map.keys(state.dirty), state, &flush_path(&2, &1))

  defp flush_path(state, path) do
    {issues, dirty} = Map.pop(state.dirty, path, MapSet.new())

    docs = Enum.reduce(issues, %{}, fn issue_id, acc -> Map.merge(acc, cached(path, issue_id)) end)
    :ok = RunRegistry.persist(path, docs, MapSet.to_list(issues))
    %{state | dirty: dirty}
  end
end
