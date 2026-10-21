defmodule SymphonyElixir.RunRegistry.Server do
  @moduledoc """
  The single writer of the run registry document (`runs.json`).

  The orchestrator records and deletes runs while the runner endpoints advance
  their event progress. Each of those is a read-modify-write of one document,
  so they are applied here one at a time: none is lost, and a progress write
  can't bring back a run that was just deleted.

  Progress without a finished reason is coalesced per run and written at most
  once per `flush_interval_ms` (1s by default), or with the next synchronous
  write to the same document. A finished reason, a record and a delete are
  written before the call returns. Pending progress is written on shutdown.

  The public API is `SymphonyElixir.RunRegistry`; when this server isn't
  running (a runner, or a bare test) its writes are applied in the caller.
  """

  use GenServer

  alias SymphonyElixir.RunRegistry

  @flush_interval_ms 1_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Applies a write to the document at `path` (with any progress pending for
  it). Returns false when the server isn't running, so the caller applies it.
  """
  @spec write(Path.t(), tuple()) :: boolean()
  def write(path, op), do: call({:write, path, op}, false)

  @doc "Buffers a run's progress for the next coalesced write; false without the server."
  @spec buffer_progress(Path.t(), String.t(), String.t(), non_neg_integer()) :: boolean()
  def buffer_progress(path, issue_id, run_id, last_seq), do: call({:progress, path, issue_id, run_id, last_seq}, false)

  @doc "Progress buffered for `path` and not yet written, by issue id."
  @spec pending(Path.t()) :: %{String.t() => {String.t(), non_neg_integer()}}
  def pending(path), do: call({:pending, path}, %{})

  @doc "Writes all buffered progress now."
  @spec flush() :: :ok
  def flush, do: call(:flush, :ok)

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
    {:ok, %{pending: %{}, timer: nil, flush_interval_ms: Keyword.get(opts, :flush_interval_ms, @flush_interval_ms)}}
  end

  @impl true
  def handle_call({:write, path, op}, _from, state) do
    {progress, state} = take_pending(state, path)
    :ok = RunRegistry.apply_ops(path, progress ++ [op])
    {:reply, true, state}
  end

  def handle_call({:progress, path, issue_id, run_id, last_seq}, _from, state) do
    runs = Map.get(state.pending, path, %{})

    seq =
      case Map.get(runs, issue_id) do
        {^run_id, pending_seq} -> max(pending_seq, last_seq)
        _ -> last_seq
      end

    state = %{state | pending: Map.put(state.pending, path, Map.put(runs, issue_id, {run_id, seq}))}
    {:reply, true, schedule_flush(state)}
  end

  def handle_call({:pending, path}, _from, state), do: {:reply, Map.get(state.pending, path, %{}), state}

  def handle_call(:flush, _from, state), do: {:reply, :ok, flush_all(state)}

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush_all(%{state | timer: nil})}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    flush_all(state)
    :ok
  end

  defp schedule_flush(%{timer: nil} = state) do
    %{state | timer: Process.send_after(self(), :flush, state.flush_interval_ms)}
  end

  defp schedule_flush(state), do: state

  defp take_pending(state, path) do
    {runs, pending} = Map.pop(state.pending, path, %{})
    ops = Enum.map(runs, fn {issue_id, {run_id, seq}} -> {:progress, issue_id, run_id, seq, nil} end)
    {ops, %{state | pending: pending}}
  end

  defp flush_all(state) do
    Enum.reduce(Map.keys(state.pending), state, fn path, acc ->
      {ops, acc} = take_pending(acc, path)
      :ok = RunRegistry.apply_ops(path, ops)
      acc
    end)
  end
end
