defmodule SymphonyElixir.RunLauncherTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunLauncher
  alias SymphonyElixir.RunLauncher.Local

  test "the default launcher is the local one, and the app env overrides it" do
    previous = Application.get_env(:symphony_elixir, :run_launcher)

    on_exit(fn -> restore(previous) end)

    Application.delete_env(:symphony_elixir, :run_launcher)
    assert RunLauncher.launcher() == Local

    Application.put_env(:symphony_elixir, :run_launcher, __MODULE__)
    assert RunLauncher.launcher() == __MODULE__
  end

  test "start runs the function and returns a reference for the pid" do
    test_pid = self()

    assert {:ok, pid, ref} =
             Local.start(
               fn ->
                 send(test_pid, {:ran, self()})
                 Process.sleep(:infinity)
               end,
               []
             )

    assert is_pid(pid)
    assert is_binary(ref)
    assert ref == Local.ref_for(pid)
    assert_receive {:ran, ^pid}
    assert Local.alive?(ref)

    assert :ok = Local.stop(ref)
    refute_eventually_alive(ref)
  end

  test "start reports an error when the task supervisor is not running" do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.TaskSupervisor)

    try do
      assert {:error, _reason} = Local.start(fn -> :ok end, [])
    after
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.TaskSupervisor)
    end
  end

  test "a reference is not alive once the task exits" do
    assert {:ok, _pid, ref} = Local.start(fn -> :ok end, [])
    refute_eventually_alive(ref)
  end

  test "a reference from another boot is not alive" do
    foreign = "local:anotherboot:" <> pid_string(self())
    refute Local.alive?(foreign)
  end

  test "a garbage reference is not alive" do
    refute Local.alive?("local:garbage")
    refute Local.alive?("nonsense")
    refute Local.alive?(nil)
    refute Local.alive?("local:" <> Local.boot_id() <> ":not-a-pid")
  end

  test "stop kills a running task and is ok for a dead or foreign reference" do
    assert {:ok, pid, ref} = Local.start(fn -> Process.sleep(:infinity) end, [])
    assert Local.alive?(ref)

    assert :ok = Local.stop(ref)
    refute Process.alive?(pid)
    refute Local.alive?(ref)

    assert :ok = Local.stop(ref)
    assert :ok = Local.stop("local:anotherboot:" <> pid_string(self()))
    assert :ok = Local.stop("nonsense")
  end

  defp refute_eventually_alive(ref, attempts \\ 50) do
    if Local.alive?(ref) and attempts > 0 do
      Process.sleep(10)
      refute_eventually_alive(ref, attempts - 1)
    else
      refute Local.alive?(ref)
    end
  end

  defp pid_string(pid) do
    pid
    |> :erlang.pid_to_list()
    |> List.to_string()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
  end

  defp restore(nil), do: Application.delete_env(:symphony_elixir, :run_launcher)
  defp restore(launcher), do: Application.put_env(:symphony_elixir, :run_launcher, launcher)
end
