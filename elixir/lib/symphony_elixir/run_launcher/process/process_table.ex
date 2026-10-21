defmodule SymphonyElixir.RunLauncher.Process.ProcessTable do
  @moduledoc """
  One shared `ps` snapshot of the host's processes for the process launcher.

  Every process run's watcher checks its runner every few seconds. Checking
  each with its own `kill -0` and `ps` costs two forks per run per poll: about
  400 a second at 1,000 runs. Instead the first check after the snapshot is
  older than `ttl_ms` (2s) takes one `ps -A -o pid= -o stat= -o lstart=`,
  and every check until then is an ETS lookup.

  The snapshot only ever confirms a run is alive (`alive?/2` returns `true`):
  a pid that is missing, a zombie, or has another start time may have
  started or ended since the snapshot was taken, so the launcher checks it
  directly (`:unknown`). A runner that dies is therefore seen at most `ttl_ms`
  later than before, well inside the watcher's lost grace.

  Without the server (a runner process, a bare test) every check is
  `:unknown`, which is the direct check.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @ttl_ms 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Whether the snapshot shows `pid` running with start time `start` (nil
  accepts any start time): `true`, or `:unknown` when only a direct check can
  tell.
  """
  @spec alive?(pos_integer(), String.t() | nil) :: true | :unknown
  def alive?(pid, start) when is_integer(pid) do
    with :ok <- ensure_fresh(),
         [{^pid, stat, actual_start}] <- lookup(pid),
         false <- String.starts_with?(stat, "Z"),
         true <- is_nil(start) or start == actual_start do
      true
    else
      _missing_zombie_or_other -> :unknown
    end
  end

  @doc """
  Drops `pid` from the snapshot, so the next check of it is direct: the
  launcher calls it after stopping a run, which the snapshot would otherwise
  still show alive.
  """
  @spec forget(pos_integer()) :: :ok
  def forget(pid) when is_integer(pid) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      server ->
        try do
          GenServer.call(server, {:forget, pid}, 10_000)
        catch
          :exit, _reason -> :ok
        end
    end
  end

  @doc "Parses `ps -o pid= -o stat= -o lstart=` output into `{pid, stat, start}` rows."
  @spec parse(String.t()) :: [{pos_integer(), String.t(), String.t()}]
  def parse(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      with [pid, stat | [_ | _] = start] <- String.split(line),
           {pid, ""} when pid > 0 <- Integer.parse(pid) do
        [{pid, stat, Enum.join(start, "_")}]
      else
        _other -> []
      end
    end)
  end

  defp lookup(pid) do
    :ets.lookup(@table, pid)
  rescue
    ArgumentError -> []
  end

  defp ensure_fresh do
    case safe_meta() do
      {:ok, taken_at_ms, ttl_ms} ->
        if now_ms() - taken_at_ms < ttl_ms, do: :ok, else: refresh()

      :none ->
        refresh()

      :unavailable ->
        :unavailable
    end
  end

  defp safe_meta do
    case :ets.lookup(@table, :meta) do
      [{:meta, taken_at_ms, ttl_ms}] -> {:ok, taken_at_ms, ttl_ms}
      [] -> :none
    end
  rescue
    ArgumentError -> :unavailable
  end

  defp refresh do
    case Process.whereis(__MODULE__) do
      nil ->
        :unavailable

      pid ->
        try do
          GenServer.call(pid, :refresh, 10_000)
        catch
          :exit, _reason -> :unavailable
        end
    end
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

    {:ok,
     %{
       ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms),
       ps: Keyword.get(opts, :ps, &run_ps/0)
     }}
  end

  @impl true
  # Concurrent callers queue here; only the first one after expiry runs ps.
  def handle_call(:refresh, _from, state) do
    case safe_meta() do
      {:ok, taken_at_ms, _ttl_ms} when is_integer(taken_at_ms) ->
        if now_ms() - taken_at_ms < state.ttl_ms, do: {:reply, :ok, state}, else: {:reply, take(state), state}

      _none ->
        {:reply, take(state), state}
    end
  end

  def handle_call({:forget, pid}, _from, state) do
    :ets.delete(@table, pid)
    {:reply, :ok, state}
  end

  defp take(state) do
    case state.ps.() do
      {:ok, rows} ->
        :ets.delete_all_objects(@table)
        :ets.insert(@table, rows)
        :ets.insert(@table, {:meta, now_ms(), state.ttl_ms})
        :ok

      {:error, reason} ->
        Logger.warning("Process table: ps failed reason=#{inspect(reason, limit: 5)}; checking runs directly")
        :unavailable
    end
  end

  defp run_ps do
    case System.cmd("ps", ["-A", "-o", "pid=", "-o", "stat=", "-o", "lstart="], stderr_to_stdout: true, env: [{"LC_ALL", "C"}]) do
      {output, 0} -> {:ok, parse(output)}
      {output, status} -> {:error, {status, String.slice(output, 0, 200)}}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
