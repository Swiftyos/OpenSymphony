defmodule SymphonyElixir.RunWatcher do
  @moduledoc """
  Watches one process-launched run from the controller.

  The orchestrator monitors the watcher exactly like it monitors an in-process
  run task, so its `:DOWN` handling (a continuation retry for `:normal`, a
  backoff retry otherwise) is the same for both launchers.

  The watcher exits with the run's `finished` reason (`:normal` for a normal
  end, otherwise `{:runner_failed, reason}`). If the OS process disappears
  without a finished event, it waits a short grace period for the runner's
  outbox to replay one, then exits `:runner_lost`. Heartbeats and every other
  event for the run update `last_seen_at`, which the orchestrator uses for
  stall detection while a process run's agent updates are in flight.
  """

  use GenServer, restart: :temporary

  require Logger

  @registry SymphonyElixir.RunWatcher.Registry
  @supervisor SymphonyElixir.RunWatcher.Supervisor
  @poll_interval_ms 5_000
  @lost_grace_ms 10_000

  @type run :: %{run_id: String.t(), issue_id: String.t() | nil}

  @doc "Starts a watcher under the controller's watcher supervisor."
  @spec start(run(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(run, ref, opts \\ []) do
    args = %{
      run_id: run_id(run),
      issue_id: Map.get(run, :issue_id),
      ref: ref,
      launcher: Keyword.get(opts, :launcher, SymphonyElixir.RunLauncher.Process),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @poll_interval_ms),
      lost_grace_ms: Keyword.get(opts, :lost_grace_ms, @lost_grace_ms)
    }

    case Process.whereis(@supervisor) do
      nil -> GenServer.start(__MODULE__, args)
      _pid -> DynamicSupervisor.start_child(@supervisor, {__MODULE__, args})
    end
  end

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @doc false
  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(args) do
    %{
      id: {__MODULE__, args.run_id},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary
    }
  end

  @doc "Tells the watcher for `run_id` that the run is still alive."
  @spec touch(String.t()) :: :ok
  def touch(run_id) when is_binary(run_id) do
    case lookup(run_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, :touch)
    end

    :ok
  end

  def touch(_run_id), do: :ok

  @doc "Sends the run's finished reason to its watcher, if it has one."
  @spec finished(String.t(), String.t()) :: :ok
  def finished(run_id, reason) when is_binary(run_id) and is_binary(reason) do
    case lookup(run_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:finished, reason})
    end

    :ok
  end

  def finished(_run_id, _reason), do: :ok

  @doc "The last time an event arrived for `run_id`, or nil when no watcher has it."
  @spec last_seen(String.t()) :: DateTime.t() | nil
  def last_seen(run_id) when is_binary(run_id) do
    case lookup(run_id) do
      nil ->
        nil

      pid ->
        try do
          GenServer.call(pid, :last_seen, 1_000)
        catch
          :exit, _reason -> nil
        end
    end
  end

  def last_seen(_run_id), do: nil

  @doc "Stops the watcher for `run_id`, usually because the run was cancelled."
  @spec stop(String.t()) :: :ok
  def stop(run_id) when is_binary(run_id) do
    case lookup(run_id) do
      nil -> :ok
      pid -> stop_pid(pid)
    end

    :ok
  end

  def stop(run_id) when is_pid(run_id), do: stop_pid(run_id)
  def stop(_run_id), do: :ok

  @doc "The Registry the watchers register in."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "The DynamicSupervisor the watchers run under."
  @spec supervisor() :: atom()
  def supervisor, do: @supervisor

  @impl true
  def init(args) do
    if Process.whereis(@registry) && Registry.lookup(@registry, args.run_id) == [] do
      Registry.register(@registry, args.run_id, nil)
    end

    schedule_poll(args.poll_interval_ms)

    {:ok,
     %{
       run_id: args.run_id,
       issue_id: args.issue_id,
       ref: args.ref,
       launcher: args.launcher,
       poll_interval_ms: args.poll_interval_ms,
       lost_grace_ms: args.lost_grace_ms,
       last_seen_ms: now_ms(),
       gone_since_ms: nil
     }}
  end

  @impl true
  def handle_cast(:touch, state), do: {:noreply, %{state | last_seen_ms: now_ms()}}

  def handle_cast({:finished, reason}, state) do
    Logger.info("Run watcher saw finished run_id=#{state.run_id} reason=#{inspect(reason)}")
    {:stop, exit_reason(reason), state}
  end

  @impl true
  def handle_call(:last_seen, _from, state) do
    {:reply, DateTime.from_unix!(state.last_seen_ms, :millisecond), state}
  end

  @impl true
  def handle_info(:poll, state) do
    if alive?(state) do
      schedule_poll(state.poll_interval_ms)
      {:noreply, %{state | gone_since_ms: nil}}
    else
      lost(state)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp lost(%{gone_since_ms: nil} = state) do
    schedule_poll(state.poll_interval_ms)
    {:noreply, %{state | gone_since_ms: now_ms()}}
  end

  defp lost(state) do
    remaining_ms = state.lost_grace_ms - (now_ms() - state.gone_since_ms)

    if remaining_ms > 0 do
      schedule_poll(min(state.poll_interval_ms, remaining_ms))
      {:noreply, state}
    else
      Logger.warning("Run watcher lost run_id=#{state.run_id} ref=#{state.ref}; no finished event within #{state.lost_grace_ms}ms")
      {:stop, :runner_lost, state}
    end
  end

  defp alive?(%{launcher: launcher, ref: ref}) do
    Code.ensure_loaded?(launcher) and function_exported?(launcher, :alive?, 1) and launcher.alive?(ref)
  rescue
    _error -> false
  end

  defp exit_reason("normal"), do: :normal
  defp exit_reason(reason), do: {:runner_failed, reason}

  defp schedule_poll(interval_ms) when is_integer(interval_ms) and interval_ms > 0,
    do: Process.send_after(self(), :poll, interval_ms)

  defp schedule_poll(_interval_ms), do: Process.send_after(self(), :poll, @poll_interval_ms)

  defp run_id(%{run_id: run_id}) when is_binary(run_id), do: run_id

  defp lookup(run_id) do
    if Process.whereis(@registry) do
      case Registry.lookup(@registry, run_id) do
        [{pid, _value}] -> pid
        [] -> nil
      end
    end
  end

  defp stop_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp now_ms, do: System.system_time(:millisecond)
end
