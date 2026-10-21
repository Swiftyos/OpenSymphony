defmodule SymphonyElixir.RunnerCommands do
  @moduledoc """
  Commands for a runner, and the controller's per-run event bookkeeping.

  A runner working over HTTP can't be `send/2`-ed a pid, so `RunHost.Remote`
  long-polls `GET /runner/v1/runs/:id/commands`: this process holds a command
  queue per issue and parks the poller until there is something to deliver
  (or its wait expires).

  It also owns the controller-side state that has to outlive one HTTP request:
  the last event `seq` applied for each run (so a replay of the runner's
  outbox is idempotent) and whether the run's `finished` event was seen (after
  which every endpoint answers `409`). The state is kept here rather than in
  the orchestrator so it is available even when the run isn't in the
  orchestrator's running set, which is exactly what step 3 needs before
  watchers exist. See `docs/durable-runs.md`.
  """

  use GenServer
  require Logger

  @type command :: %{seq: pos_integer(), type: String.t(), message_id: String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Queues a command for the issue's runner and wakes any waiting poller."
  @spec push(String.t(), map()) :: :ok
  def push(identifier, command) when is_binary(identifier) and is_map(command) do
    call({:push, identifier, command}, :ok, :infinity)
  end

  def push(_identifier, _command), do: :ok

  @doc """
  Commands for `key` after `after_seq`, waiting up to `wait_ms` for one to
  arrive. `key` is the issue identifier (the controller resolves a run id to
  it before calling).
  """
  @spec fetch(String.t(), non_neg_integer(), non_neg_integer()) :: [command()]
  def fetch(key, after_seq \\ 0, wait_ms \\ 0)

  def fetch(key, after_seq, wait_ms)
      when is_binary(key) and is_integer(after_seq) and after_seq >= 0 and is_integer(wait_ms) and wait_ms >= 0 do
    call({:fetch, key, after_seq, wait_ms}, [], :infinity)
  end

  def fetch(_key, _after_seq, _wait_ms), do: []

  @doc """
  Applies the events a runner hasn't sent before, in seq order, once each.

  `fun` is called for each new event before the last seq is recorded. Returns
  `{:ok, last_seq}` (the highest seq now applied) or `{:error, :finished}`
  once the run's `finished` event has been applied.
  """
  @spec apply_events(String.t(), [map()], (map() -> any())) ::
          {:ok, non_neg_integer()} | {:error, :finished | :unavailable}
  def apply_events(run_id, events, fun)
      when is_binary(run_id) and is_list(events) and is_function(fun, 1) do
    call({:apply_events, run_id, events, fun}, {:error, :unavailable}, :infinity)
  end

  def apply_events(_run_id, _events, _fun), do: {:error, :unavailable}

  @doc "Whether the run's finished event has been applied."
  @spec finished?(String.t()) :: boolean()
  def finished?(run_id) when is_binary(run_id), do: call({:finished?, run_id}, false, :infinity)
  def finished?(_run_id), do: false

  @doc "The last event seq applied for the run."
  @spec last_seq(String.t()) :: non_neg_integer()
  def last_seq(run_id) when is_binary(run_id), do: call({:last_seq, run_id}, 0, :infinity)
  def last_seq(_run_id), do: 0

  @doc "Forgets all commands and run bookkeeping (tests, and a fresh controller boot)."
  @spec reset() :: :ok
  def reset, do: call(:reset, :ok, :infinity)

  defp call(message, fallback, timeout) do
    case Process.whereis(__MODULE__) do
      nil ->
        fallback

      _pid ->
        try do
          GenServer.call(__MODULE__, message, timeout)
        catch
          :exit, reason ->
            Logger.warning("Runner commands unavailable request=#{inspect(message_name(message))} reason=#{inspect(reason, limit: 5)}")
            fallback
        end
    end
  end

  defp message_name(message) when is_tuple(message), do: elem(message, 0)
  defp message_name(message), do: message

  @impl true
  def init(_opts) do
    {:ok, %{commands: %{}, next_seq: 1, waiters: %{}, runs: %{}}}
  end

  @impl true
  def handle_call({:push, identifier, command}, _from, state) do
    seq = state.next_seq

    entry =
      command
      |> Map.put(:seq, seq)
      |> Map.put_new(:type, "agent_inbox")
      |> Map.new(fn {key, value} -> {key, value} end)

    commands = Map.update(state.commands, identifier, [entry], &(&1 ++ [entry]))
    state = %{state | commands: commands, next_seq: seq + 1}
    {:reply, :ok, notify_waiters(state, identifier)}
  end

  def handle_call({:fetch, key, after_seq, wait_ms}, from, state) do
    case newer(state.commands, key, after_seq) do
      [] when wait_ms == 0 ->
        {:reply, [], state}

      [] ->
        ref = make_ref()
        timer = Process.send_after(self(), {:waiter_timeout, ref}, wait_ms)
        waiters = Map.put(state.waiters, ref, %{from: from, key: key, after_seq: after_seq, timer: timer})
        {:noreply, %{state | waiters: waiters}}

      commands ->
        {:reply, commands, state}
    end
  end

  def handle_call({:apply_events, run_id, events, fun}, _from, state) do
    run = Map.get(state.runs, run_id, %{last_seq: 0, finished: nil})

    case run.finished do
      reason when is_binary(reason) ->
        {:reply, {:error, :finished}, state}

      _ ->
        {last_seq, finished} = apply_new_events(events, run.last_seq, nil, fun)
        run = %{run | last_seq: last_seq, finished: finished}
        {:reply, {:ok, last_seq}, %{state | runs: Map.put(state.runs, run_id, run)}}
    end
  end

  def handle_call({:finished?, run_id}, _from, state) do
    {:reply, is_binary(Map.get(state.runs, run_id, %{})[:finished]), state}
  end

  def handle_call({:last_seq, run_id}, _from, state) do
    {:reply, Map.get(state.runs, run_id, %{last_seq: 0}).last_seq, state}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.waiters, fn {_ref, waiter} ->
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, [])
    end)

    {:reply, :ok, %{commands: %{}, next_seq: 1, waiters: %{}, runs: %{}}}
  end

  @impl true
  def handle_info({:waiter_timeout, ref}, state) do
    case Map.pop(state.waiters, ref) do
      {nil, _waiters} ->
        {:noreply, state}

      {waiter, waiters} ->
        GenServer.reply(waiter.from, [])
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp notify_waiters(state, identifier) do
    {notified, waiters} =
      Enum.reduce(state.waiters, {[], %{}}, fn {ref, waiter}, {notified, kept} ->
        notify_waiter(state, ref, waiter, identifier, notified, kept)
      end)

    if notified == [], do: state, else: %{state | waiters: waiters}
  end

  defp notify_waiter(_state, ref, %{key: key} = waiter, identifier, notified, kept) when key != identifier do
    {notified, Map.put(kept, ref, waiter)}
  end

  defp notify_waiter(state, ref, waiter, identifier, notified, kept) do
    case newer(state.commands, identifier, waiter.after_seq) do
      [] ->
        {notified, Map.put(kept, ref, waiter)}

      commands ->
        Process.cancel_timer(waiter.timer)
        GenServer.reply(waiter.from, commands)
        {[ref | notified], kept}
    end
  end

  defp newer(commands, key, after_seq) do
    commands
    |> Map.get(key, [])
    |> Enum.filter(&(&1.seq > after_seq))
    |> Enum.sort_by(& &1.seq)
  end

  defp apply_new_events(events, last_seq, finished, fun) do
    fresh =
      events
      |> Enum.filter(&(valid_event?(&1) and &1.seq > last_seq))
      |> Enum.sort_by(& &1.seq)
      |> Enum.uniq_by(& &1.seq)

    Enum.reduce(fresh, {last_seq, finished}, fn event, {current_seq, finished} ->
      if is_binary(finished) do
        {current_seq, finished}
      else
        fun.(event)
        {event.seq, finished_reason(event)}
      end
    end)
  end

  defp valid_event?(%{seq: seq, type: type}) when is_integer(seq) and seq >= 0 and is_binary(type), do: true
  defp valid_event?(_event), do: false

  defp finished_reason(%{type: "finished", data: data}) when is_map(data) do
    Map.get(data, :reason) || Map.get(data, "reason") || "finished"
  end

  defp finished_reason(_event), do: nil
end
