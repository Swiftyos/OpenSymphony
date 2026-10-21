defmodule SymphonyElixir.RunLauncherTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunLauncher
  alias SymphonyElixir.RunLauncher.Local
  alias SymphonyElixir.RunSpec

  defmodule StubProcessLauncher do
    def start(fun, _opts) do
      fun.()
      {:ok, self(), "stub:function"}
    end

    def start_process(spec, opts) do
      if fun = Keyword.get(opts, :fun), do: fun.()
      run_id = if is_map(spec), do: spec.run_id, else: "function"
      {:ok, self(), "stub:" <> run_id}
    end

    def alive?(_ref), do: true
    def stop(_ref), do: :ok
  end

  test "the default launcher is the local one, and the app env overrides it" do
    previous = Application.get_env(:symphony_elixir, :run_launcher)

    on_exit(fn -> restore(previous) end)

    Application.delete_env(:symphony_elixir, :run_launcher)
    assert RunLauncher.launcher() == Local

    Application.put_env(:symphony_elixir, :run_launcher, __MODULE__)
    assert RunLauncher.launcher() == __MODULE__
  end

  test "RunLauncher.start sends function launchers the run function and process launchers the spec" do
    parent = self()

    assert {:ok, _pid, _ref} = RunLauncher.start(Local, fn -> :ok end)

    assert {:ok, pid, "local:" <> _} =
             RunLauncher.start(Local, fn -> send(parent, :local_ran) end, [])

    assert_receive :local_ran
    Local.stop(Local.ref_for(pid))

    request = %{fun: fn -> send(parent, :process_ran) end, spec: %RunSpec{run_id: "run-dispatch", epoch: 1}}

    assert {:ok, _pid, "stub:run-dispatch"} = RunLauncher.start(StubProcessLauncher, request, [])
    assert_receive :process_ran

    spec = %RunSpec{run_id: "run-spec", epoch: 1}
    assert {:ok, _pid, "stub:run-spec"} = RunLauncher.start(StubProcessLauncher, spec, [])
    assert {:ok, _pid, "stub:run-spec"} = RunLauncher.start(StubProcessLauncher, spec, fun: fn -> :ok end)
    assert {:ok, _pid, "stub:function"} = RunLauncher.start(StubProcessLauncher, fn -> :ok end, [])
    assert {:ok, _pid, "stub:function"} = RunLauncher.start(StubProcessLauncher, :not_a_fun_or_spec, [])
  end

  test "a config error falls back to the local launcher" do
    previous_env = Application.get_env(:symphony_elixir, :run_launcher)
    previous_path = SymphonyElixir.Workflow.workflow_file_path()
    Application.delete_env(:symphony_elixir, :run_launcher)
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    try do
      SymphonyElixir.Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-launcher-workflow-#{System.unique_integer([:positive])}.md"))
      assert RunLauncher.launcher() == Local
    after
      SymphonyElixir.Workflow.set_workflow_file_path(previous_path)
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      restore(previous_env)
    end
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
