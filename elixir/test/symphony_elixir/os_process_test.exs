defmodule SymphonyElixir.OsProcessTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.OsProcess

  test "stop_port ends a process that ignores stdin, and its children" do
    root = Path.join(System.tmp_dir!(), "symphony-os-process-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    pid_file = Path.join(root, "pids")
    on_exit(fn -> File.rm_rf(root) end)

    script = ~s(trap '' TERM; sleep 300 & printf '%s %s\\n' "$$" "$!" > '#{pid_file}'; while true; do sleep 1; done)
    port = Port.open({:spawn_executable, System.find_executable("sh")}, [:binary, args: ["-c", script]])

    pids = wait_for_pids(pid_file)
    assert Enum.all?(pids, &OsProcess.alive?/1)

    # The shell ignores TERM, so this also covers the KILL fallback.
    assert :ok = OsProcess.stop_port(port)
    refute Enum.any?(pids, &OsProcess.alive?/1)

    # A closed port is fine too.
    assert :ok = OsProcess.stop_port(port)
  end

  test "terminate/1 with nothing to stop" do
    assert :ok = OsProcess.terminate([])
  end

  defp wait_for_pids(file, attempts \\ 100) do
    case File.read(file) do
      {:ok, body} when body != "" ->
        body |> String.split() |> Enum.map(&String.to_integer/1)

      _ when attempts > 0 ->
        Process.sleep(20)
        wait_for_pids(file, attempts - 1)

      _ ->
        flunk("the script never wrote its pids")
    end
  end
end
