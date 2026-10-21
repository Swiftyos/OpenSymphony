defmodule SymphonyElixir.OsProcess do
  @moduledoc """
  Stops the OS process behind an agent backend's port, and what it started.

  `Port.close/1` only closes the pipes: a program that never reads stdin (a
  long-running `opencode serve`, or a `bash -lc` wrapper around one) keeps
  running, orphaned. `stop_port/1` reads the port's OS pid first, then sends
  TERM to that process's group, the process and its descendants (a port is not
  a group leader, and `bash -lc` may leave its child running), waits a moment,
  and sends KILL to whatever is still alive.
  """

  @grace_ms 500
  @kill_wait_ms 500
  @poll_ms 25

  @doc """
  Closes a port and makes sure its OS process tree is gone. Safe to call on a
  port that is already closed.
  """
  @spec stop_port(port()) :: :ok
  def stop_port(port) when is_port(port) do
    os_pid =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
        _ -> nil
      end

    pids = if os_pid, do: [os_pid | descendants(os_pid)], else: []

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    terminate(pids)
  end

  @doc """
  TERM, then (after a grace period) KILL, for these OS pids; each pid's
  process group is signalled too when it leads one.
  """
  @spec terminate([pos_integer()]) :: :ok
  def terminate([]), do: :ok

  def terminate(pids) when is_list(pids) do
    Enum.each(pids, &signal(&1, "TERM"))

    unless wait_for_exit(pids, @grace_ms) do
      pids |> Enum.filter(&alive?/1) |> Enum.each(&signal(&1, "KILL"))
      wait_for_exit(pids, @kill_wait_ms)
    end

    :ok
  end

  @doc """
  Whether an OS process with this pid exists.
  """
  @spec alive?(pos_integer()) :: boolean()
  def alive?(pid) when is_integer(pid) do
    match?({_output, 0}, System.cmd("kill", ["-0", "--", Integer.to_string(pid)], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  # Children first-level and below, from `pgrep -P`.
  defp descendants(pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} ->
        children = for line <- String.split(output, "\n", trim: true), {child, ""} <- [Integer.parse(String.trim(line))], do: child
        children ++ Enum.flat_map(children, &descendants/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp signal(pid, signal) do
    System.cmd("kill", ["-#{signal}", "--", "-#{pid}"], stderr_to_stdout: true)
    System.cmd("kill", ["-#{signal}", "--", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp wait_for_exit(pids, remaining_ms) do
    cond do
      not Enum.any?(pids, &alive?/1) ->
        true

      remaining_ms <= 0 ->
        false

      true ->
        Process.sleep(@poll_ms)
        wait_for_exit(pids, remaining_ms - @poll_ms)
    end
  end
end
