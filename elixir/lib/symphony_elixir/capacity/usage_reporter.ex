defmodule SymphonyElixir.Capacity.UsageReporter do
  @moduledoc """
  Reports a runner's own CPU and memory to the controller.

  Started by `SymphonyElixir.Runner` for the run's lifetime. Every
  `capacity.sample_interval_ms` (30s by default; 0 turns it off) it reads
  `SymphonyElixir.Capacity.SelfUsage` and appends a `metrics` event to the
  run's outbox:

      %{run_id: ..., cpu_percent: 85.0, cpu_seconds: 120.5,
        memory_bytes: 734_003_200, source: "cgroup_v2"}

  `cpu_percent` (percent of one CPU, like the VM sampler's) is the CPU time
  used since the previous reading over the wall time between them; it is nil
  when there is no comparable previous reading (the source changed, or the
  counter went backwards). The controller turns these events into the same
  `symphony_run_cpu_percent` and `symphony_run_memory_bytes` series the VM
  sampler produces (`SymphonyElixir.Capacity.RunUsage`). A reading that fails
  is skipped.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Capacity.SelfUsage
  alias SymphonyElixir.RunOutbox

  @doc """
  Starts a reporter (not linked: a failing reporter must not end the run).
  Options: `:outbox` and `:run_id` (required), `:interval_ms`, `:reader`
  (a zero-arity function returning `SelfUsage.read/1`'s result) and `:clock`
  (monotonic milliseconds).
  """
  @spec start(keyword()) :: GenServer.on_start() | :ignore
  def start(opts) do
    case Keyword.get(opts, :interval_ms) do
      interval when is_integer(interval) and interval > 0 -> GenServer.start(__MODULE__, opts)
      _off -> :ignore
    end
  end

  @doc "Stops a reporter started by `start/1` (its pid or its result); anything else is ignored."
  @spec stop(pid() | {:ok, pid()} | term()) :: :ok
  def stop({:ok, pid}) when is_pid(pid), do: stop(pid)

  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _reason -> :ok
  end

  def stop(_other), do: :ok

  @impl true
  def init(opts) do
    state = %{
      outbox: Keyword.fetch!(opts, :outbox),
      run_id: Keyword.fetch!(opts, :run_id),
      interval_ms: Keyword.fetch!(opts, :interval_ms),
      reader: Keyword.get(opts, :reader, fn -> SelfUsage.read() end),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      previous: nil,
      warned?: false
    }

    schedule(state)
    {:ok, reading(state)}
  end

  @impl true
  def handle_info(:report, state) do
    schedule(state)
    state = reading(state)
    if state.reported_now?, do: append(state, elem(state.previous, 0))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Reads the usage and keeps it as the next baseline, with the CPU percent
  # since the last one.
  defp reading(state) do
    now = state.clock.()

    case safe_read(state.reader) do
      {:ok, sample} ->
        sample = Map.put(sample, :cpu_percent, cpu_percent(state.previous, sample, now))
        Map.merge(state, %{previous: {sample, now}, reported_now?: true})

      {:error, reason} ->
        unless state.warned?, do: Logger.warning("Runner usage reading failed reason=#{inspect(reason, limit: 5)}")
        Map.merge(state, %{warned?: true, reported_now?: false})
    end
  end

  defp safe_read(reader) do
    case reader.() do
      {:ok, %{cpu_seconds: seconds, memory_bytes: bytes}} = ok when is_number(seconds) and is_integer(bytes) -> ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_reading, other}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp cpu_percent({%{cpu_seconds: before} = previous, at}, %{cpu_seconds: seconds} = sample, now)
       when now > at and seconds >= before do
    if Map.get(previous, :source) == Map.get(sample, :source), do: (seconds - before) * 100_000 / (now - at)
  end

  defp cpu_percent(_previous, _sample, _now), do: nil

  defp append(state, sample) do
    RunOutbox.append(state.outbox, "metrics", %{
      run_id: state.run_id,
      cpu_percent: sample.cpu_percent,
      cpu_seconds: sample.cpu_seconds,
      memory_bytes: sample.memory_bytes,
      source: Map.get(sample, :source)
    })
  end

  defp schedule(state), do: Process.send_after(self(), :report, state.interval_ms)
end
