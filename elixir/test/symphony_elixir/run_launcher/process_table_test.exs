defmodule SymphonyElixir.RunLauncher.Process.ProcessTableTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunLauncher.Process, as: ProcessLauncher
  alias SymphonyElixir.RunLauncher.Process.ProcessTable

  test "parses ps output into pid, state and start time rows" do
    output = """
      1 Ss   Tue Oct 21 18:02:00 2026
    4242 R+   Wed Oct 22 09:15:07 2026
    garbage
     0 S    Tue Oct 21 18:02:00 2026
     77 Z
    """

    assert ProcessTable.parse(output) == [
             {1, "Ss", "Tue_Oct_21_18:02:00_2026"},
             {4242, "R+", "Wed_Oct_22_09:15:07_2026"}
           ]
  end

  test "the application's table confirms this BEAM alive and leaves others to a direct check" do
    os_pid = System.pid() |> String.to_integer()
    assert ProcessTable.alive?(os_pid, nil) == true
    assert ProcessTable.alive?(os_pid, "not-its-start-time") == :unknown
    assert ProcessTable.alive?(999_999_999, nil) == :unknown

    # The launcher's reference check agrees with the direct one.
    {output, 0} = System.cmd("ps", ["-o", "lstart=", "-p", System.pid()], env: [{"LC_ALL", "C"}])
    start = output |> String.split() |> Enum.join("_")
    assert ProcessLauncher.alive?("process:#{os_pid}:#{start}")
    refute ProcessLauncher.alive?("process:#{os_pid}:another-start")
  end

  test "one ps serves every check within the TTL; zombies and missing pids are unknown" do
    parent = self()

    ps = fn ->
      send(parent, :ps_ran)
      {:ok, [{100, "S", "start-a"}, {101, "Z", "start-b"}]}
    end

    with_table([ttl_ms: 200, ps: ps], fn ->
      for _ <- 1..1_000, do: assert(ProcessTable.alive?(100, "start-a") == true)
      assert_received :ps_ran
      refute_received :ps_ran

      assert ProcessTable.alive?(100, nil) == true
      assert ProcessTable.alive?(100, "start-other") == :unknown
      assert ProcessTable.alive?(101, "start-b") == :unknown
      assert ProcessTable.alive?(102, nil) == :unknown

      # A forgotten pid (a stopped run) is checked directly until the next snapshot.
      assert ProcessTable.forget(100) == :ok
      assert ProcessTable.alive?(100, "start-a") == :unknown

      # Concurrent checks after expiry still take one snapshot.
      Process.sleep(250)

      1..50
      |> Enum.map(fn _ -> Task.async(fn -> ProcessTable.alive?(100, "start-a") end) end)
      |> Enum.each(&assert(Task.await(&1) == true))

      assert_received :ps_ran
      refute_received :ps_ran
    end)
  end

  test "a failing ps, or no server, leaves every check to the direct one" do
    with_table([ps: fn -> {:error, :boom} end], fn ->
      log = capture_log(fn -> assert ProcessTable.alive?(100, nil) == :unknown end)
      assert log =~ "Process table: ps failed"
    end)

    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, ProcessTable)

    try do
      assert ProcessTable.alive?(100, nil) == :unknown
      assert ProcessTable.forget(100) == :ok
      # A stopped table falls back to the direct check.
      os_pid = System.pid()
      {output, 0} = System.cmd("ps", ["-o", "lstart=", "-p", os_pid], env: [{"LC_ALL", "C"}])
      assert ProcessLauncher.alive?("process:#{os_pid}:#{output |> String.split() |> Enum.join("_")}")
    after
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, ProcessTable)
    end
  end

  # Replaces the application's table with one built from `opts` for `fun`.
  defp with_table(opts, fun) do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, ProcessTable)

    try do
      {:ok, pid} = GenServer.start(ProcessTable, opts, name: ProcessTable)

      try do
        fun.()
      after
        GenServer.stop(pid)
      end
    after
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, ProcessTable)
    end
  end
end
