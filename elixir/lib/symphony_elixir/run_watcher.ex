defmodule SymphonyElixir.RunWatcher do
  @moduledoc """
  Watches one process-launched or Kubernetes run from the controller.

  The orchestrator monitors the watcher exactly like it monitors an in-process
  run task, so its `:DOWN` handling (a continuation retry for `:normal`, a
  backoff retry otherwise) is the same for both launchers.

  The watcher exits with the run's `finished` reason (`:normal` for a normal
  end, otherwise `{:runner_failed, reason}`). If the OS process disappears
  without a finished event, it waits a short grace period for the runner's
  outbox to replay one, then exits `:runner_lost` (or the reason the launcher
  gave for the run's end, such as a pod's `{:pod_failed, "OOMKilled (exit code
  137)"}`).

  The run is checked with `SymphonyElixir.RunLauncher.status/2` (or a `:status`
  function given at start). A check that fails (`{:unknown, reason}`) is
  retried at the next poll without starting the lost clock. One that is refused
  (`{:unauthorized, reason}`, a 401/403) for longer than
  `unauthorized_timeout_ms` (five minutes) exits
  `{:pod_monitor_unauthorized, reason}`, since the controller has lost access.

  A watcher started with `log:` (a just-launched runner's `runner.log`) checks
  the runner once after `startup_check_ms` (1s) before its regular polling. A
  runner already gone then, with no finished event, never really started: the
  watcher exits `{:launch_failed, log_tail}` with the last 2000 bytes of its log,
  so the launcher itself never waits for the runner. Heartbeats and every other
  event for the run update `last_seen_at`, which the orchestrator uses for
  stall detection while a process run's agent updates are in flight.
  """

  use GenServer, restart: :temporary

  require Logger

  alias SymphonyElixir.RunWatcher.LastSeen

  @registry SymphonyElixir.RunWatcher.Registry
  @supervisor SymphonyElixir.RunWatcher.Supervisor
  @poll_interval_ms 5_000
  @lost_grace_ms 10_000
  @startup_check_ms 1_000
  @unauthorized_timeout_ms 300_000
  @log_tail_bytes 2_000

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
      lost_grace_ms: Keyword.get(opts, :lost_grace_ms, @lost_grace_ms),
      log: Keyword.get(opts, :log),
      startup_check_ms: Keyword.get(opts, :startup_check_ms, @startup_check_ms),
      status: Keyword.get(opts, :status),
      startup_status: Keyword.get(opts, :startup_status),
      unauthorized_timeout_ms: Keyword.get(opts, :unauthorized_timeout_ms, @unauthorized_timeout_ms)
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

  @doc """
  Tells the watcher for `run_id` that the run is still alive. Called for every
  runner event: it writes the shared last-seen table (`RunWatcher.LastSeen`)
  directly, without a message to the watcher.
  """
  @spec touch(String.t()) :: :ok
  def touch(run_id) when is_binary(run_id) do
    case lookup(run_id) do
      nil -> :ok
      pid -> if LastSeen.put(run_id, pid, now_ms()) == :unavailable, do: GenServer.cast(pid, :touch)
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

  @doc """
  The last time an event arrived for `run_id`, or nil when no watcher has it.
  An ETS read (the orchestrator asks for every run on each poll); a call to
  the watcher only without the shared table.
  """
  @spec last_seen(String.t()) :: DateTime.t() | nil
  def last_seen(run_id) when is_binary(run_id) do
    case lookup(run_id) do
      nil -> nil
      pid -> last_seen_of(run_id, pid)
    end
  end

  def last_seen(_run_id), do: nil

  defp last_seen_of(run_id, pid) do
    case LastSeen.get(run_id, pid) do
      ms when is_integer(ms) -> DateTime.from_unix!(ms, :millisecond)
      nil -> nil
      :unavailable -> call_last_seen(pid)
    end
  end

  defp call_last_seen(pid) do
    GenServer.call(pid, :last_seen, 1_000)
  catch
    :exit, _reason -> nil
  end

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
    # One watcher per run: a second would give the run two exits.
    case Process.whereis(@registry) && Registry.register(@registry, args.run_id, nil) do
      {:error, {:already_registered, pid}} -> {:stop, {:already_watched, pid}}
      _registered_or_no_registry -> init_watcher(args)
    end
  end

  defp init_watcher(args) do
    now = now_ms()
    LastSeen.put(args.run_id, self(), now)
    # A just-launched runner is checked once at startup_check_ms; regular
    # polling starts after that check passes.
    case Map.get(args, :log) do
      nil -> schedule_poll(args.poll_interval_ms)
      _log -> Process.send_after(self(), :startup_check, max(Map.get(args, :startup_check_ms, @startup_check_ms), 0))
    end

    {:ok,
     %{
       run_id: args.run_id,
       issue_id: args.issue_id,
       ref: args.ref,
       launcher: args.launcher,
       poll_interval_ms: args.poll_interval_ms,
       lost_grace_ms: args.lost_grace_ms,
       log: Map.get(args, :log),
       status: Map.get(args, :status),
       startup_status: Map.get(args, :startup_status),
       unauthorized_timeout_ms: Map.get(args, :unauthorized_timeout_ms, @unauthorized_timeout_ms),
       last_seen_ms: now,
       gone_since_ms: nil,
       unauthorized_since_ms: nil
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
  def handle_info(:startup_check, state) do
    if startup_status(state) == :alive do
      schedule_poll(state.poll_interval_ms)
      {:noreply, state}
    else
      tail = log_tail(state.log)
      Logger.warning("Run watcher: runner exited at launch run_id=#{state.run_id} ref=#{state.ref} log_tail=#{inspect(tail)}")
      {:stop, {:launch_failed, tail}, state}
    end
  end

  def handle_info(:poll, state) do
    case status(state) do
      :alive ->
        schedule_poll(state.poll_interval_ms)
        {:noreply, %{state | gone_since_ms: nil, unauthorized_since_ms: nil}}

      {:gone, reason} ->
        lost(state, reason)

      {:unauthorized, reason} ->
        unauthorized(state, reason)

      {:unknown, reason} ->
        Logger.warning("Run watcher could not check run_id=#{state.run_id} ref=#{state.ref} reason=#{inspect(reason, limit: 5)}")
        schedule_poll(state.poll_interval_ms)
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    LastSeen.delete(state.run_id, self())
    :ok
  end

  defp lost(%{gone_since_ms: nil} = state, _reason) do
    schedule_poll(state.poll_interval_ms)
    {:noreply, %{state | gone_since_ms: now_ms(), unauthorized_since_ms: nil}}
  end

  defp lost(state, reason) do
    remaining_ms = state.lost_grace_ms - (now_ms() - state.gone_since_ms)

    if remaining_ms > 0 do
      schedule_poll(min(state.poll_interval_ms, remaining_ms))
      {:noreply, state}
    else
      Logger.warning("Run watcher lost run_id=#{state.run_id} ref=#{state.ref} reason=#{inspect(reason, limit: 5)}; no finished event within #{state.lost_grace_ms}ms")
      {:stop, reason || :runner_lost, state}
    end
  end

  # A rotated token is picked up on the next request, so a short burst of
  # 401/403 is retried; one that persists means the controller lost access.
  defp unauthorized(state, reason) do
    now = now_ms()
    since = state.unauthorized_since_ms || now

    if now - since >= state.unauthorized_timeout_ms do
      Logger.error("Run watcher unauthorized for too long run_id=#{state.run_id} ref=#{state.ref} reason=#{inspect(reason, limit: 5)}")
      {:stop, {:pod_monitor_unauthorized, reason}, state}
    else
      Logger.warning("Run watcher check unauthorized run_id=#{state.run_id} ref=#{state.ref} reason=#{inspect(reason, limit: 5)}")
      schedule_poll(state.poll_interval_ms)
      {:noreply, %{state | unauthorized_since_ms: since}}
    end
  end

  # The startup check can be given its own, exact check (the process
  # launcher's shared ps snapshot may still show a runner that just died).
  defp startup_status(%{startup_status: status} = state) when is_function(status, 0), do: status(%{state | status: status})
  defp startup_status(state), do: status(state)

  defp status(%{status: status}) when is_function(status, 0) do
    status.()
  rescue
    _error -> {:gone, nil}
  end

  defp status(%{launcher: launcher, ref: ref}), do: SymphonyElixir.RunLauncher.status(launcher, ref)

  @doc "The exit reason for a run's finished reason: `:normal`, or `{:runner_failed, reason}`."
  @spec exit_reason(String.t()) :: :normal | {:runner_failed, String.t()}
  def exit_reason("normal"), do: :normal
  def exit_reason(reason), do: {:runner_failed, reason}

  defp log_tail(log) do
    case File.read(log) do
      {:ok, body} when byte_size(body) > @log_tail_bytes ->
        binary_part(body, byte_size(body) - @log_tail_bytes, @log_tail_bytes)

      {:ok, body} ->
        body

      {:error, _reason} ->
        ""
    end
  end

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
