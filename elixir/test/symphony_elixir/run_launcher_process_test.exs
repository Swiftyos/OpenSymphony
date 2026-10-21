defmodule SymphonyElixir.RunLauncher.ProcessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunLauncher
  alias SymphonyElixir.RunLauncher.Process, as: ProcessLauncher
  alias SymphonyElixir.RunSpec
  alias SymphonyElixir.RunWatcher

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-process-launcher-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_state_root = Application.get_env(:symphony_elixir, :state_root)
    Application.put_env(:symphony_elixir, :state_root, Path.join(root, "state"))

    on_exit(fn ->
      case previous_state_root do
        nil -> Application.delete_env(:symphony_elixir, :state_root)
        value -> Application.put_env(:symphony_elixir, :state_root, value)
      end

      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "a spec starts a detached process, records its spec, and can be stopped", %{root: root} do
    script = write_sleep_script!(root)
    spec = spec(root, "run-process-stop")
    command = "#{script} {spec} {run_id}"

    assert {:ok, watcher, "process:" <> pid} =
             ProcessLauncher.start_process(spec,
               command: command,
               symphony: nil,
               poll_interval_ms: 20,
               lost_grace_ms: 200
             )

    assert is_pid(watcher)
    assert File.exists?(RunSpec.path(spec.run_id))
    assert eventually(fn -> File.read(Path.join(root, "started")) == {:ok, RunSpec.path(spec.run_id)} end)
    assert ProcessLauncher.alive?("process:" <> pid)

    assert :ok = ProcessLauncher.stop("process:" <> pid)
    refute eventually(fn -> ProcessLauncher.alive?("process:" <> pid) end)

    assert :ok = ProcessLauncher.stop("process:" <> pid)
    assert :ok = ProcessLauncher.stop("nonsense")
    assert :ok = ProcessLauncher.stop("process:not-a-pid")
    RunWatcher.stop(spec.run_id)
  end

  test "start/2 accepts a request map or a spec and returns an error without a spec", %{root: root} do
    spec = spec(root, "run-process-map")
    command = "#{write_sleep_script!(root)} {spec}"

    assert {:error, :missing_run_spec} = ProcessLauncher.start(fn -> :ok end, [])
    assert {:error, :missing_run_spec} = ProcessLauncher.start(:nope, [])
    assert {:ok, watcher, ref} = ProcessLauncher.start(%{spec: spec, fun: fn -> :ok end}, command: command, startup_check_ms: 0)
    assert is_pid(watcher)
    assert is_binary(ref)
    RunWatcher.stop(spec.run_id)
    ProcessLauncher.stop(ref)

    assert {:ok, watcher, ref} = ProcessLauncher.start(spec, command: command, startup_check_ms: 0)
    assert is_pid(watcher)
    assert is_binary(ref)
    RunWatcher.stop(spec.run_id)
    ProcessLauncher.stop(ref)
  end

  test "invalid specs, commands and missing binaries are reported", %{root: root} do
    spec = spec(root, "run-process-errors")

    assert {:error, _reason} = ProcessLauncher.start_process(spec, command: 123)
    assert {:error, :missing_symphony_binary} = ProcessLauncher.start_process(spec, command: "{symphony} runner {spec}", symphony: nil)
    assert {:error, :missing_systemd_unit} = ProcessLauncher.start_process(spec, command: "systemd-run /bin/true")

    assert {:error, {:launch_failed, _status, _output}} =
             ProcessLauncher.start_process(spec, command: "systemd-run --unit=symphony-test /bin/false")

    assert {:error, {:launch_failed, _status, _output}} =
             ProcessLauncher.start_process(spec, command: "'unterminated {spec}")

    # A spec that cannot be written fails before any process starts.
    file = Path.join(root, "not-a-dir")
    File.write!(file, "")
    Application.put_env(:symphony_elixir, :state_root, file)
    assert {:error, _reason} = ProcessLauncher.start_process(spec, command: "true {spec}")
    assert {:error, _reason} = ProcessLauncher.start_process(spec)
  after
    :ok
  end

  test "a runner that is missing or exits at once makes its watcher exit {:launch_failed, log_tail}", %{root: root} do
    spec = spec(root, "run-missing-runner")

    # The launch itself returns at once; the watcher's startup check finds the runner gone.
    {elapsed_us, result} =
      :timer.tc(fn ->
        ProcessLauncher.start_process(spec, command: "#{Path.join(root, "no-such-runner")} {spec}", startup_check_ms: 300)
      end)

    assert {:ok, watcher, "process:" <> _rest} = result
    assert elapsed_us < 300_000
    output = assert_launch_failed(watcher)
    assert output =~ "no-such-runner"
    refute RunWatcher.last_seen(spec.run_id)

    # Exited within the startup check, with only the log's tail kept.
    script = Path.join(root, "noisy-exit.sh")
    File.write!(script, "#!/bin/sh\nprintf 'x%.0s' $(seq 1 3000)\necho boom >&2\nsleep 0.2\nexit 3\n")
    File.chmod!(script, 0o755)

    assert {:ok, watcher, _ref} = ProcessLauncher.start_process(spec(root, "run-noisy"), command: "#{script} {spec}", startup_check_ms: 600)
    tail = assert_launch_failed(watcher)
    assert byte_size(tail) == 2_000
    assert tail =~ "boom"

    # A runner that removes its own run dir leaves no log to show.
    remover = Path.join(root, "remove-dir.sh")
    File.write!(remover, "#!/bin/sh\nrm -rf \"$(dirname \"$1\")\"\nsleep 0.2\n")
    File.chmod!(remover, 0o755)
    assert {:ok, watcher, _ref} = ProcessLauncher.start_process(spec(root, "run-no-log"), command: "#{remover} {spec}", startup_check_ms: 600)
    assert assert_launch_failed(watcher) == ""
  end

  test "the runner gets stdin from /dev/null and its output in runner.log", %{root: root} do
    script = Path.join(root, "chatty.sh")
    File.write!(script, "#!/bin/sh\necho \"hello from $1\"\nread line && echo \"stdin: $line\"\necho 'stdin closed'\nexec sleep 1000\n")
    File.chmod!(script, 0o755)
    spec = spec(root, "run-chatty")

    assert {:ok, _watcher, ref} = ProcessLauncher.start_process(spec, command: "#{script} {spec}", startup_check_ms: 200)
    log = Path.join(RunSpec.dir(spec.run_id), "runner.log")
    assert eventually(fn -> File.read!(log) =~ "stdin closed" end)
    assert File.read!(log) =~ "hello from #{RunSpec.path(spec.run_id)}"
    refute File.read!(log) =~ "stdin:"

    assert :ok = ProcessLauncher.stop(ref)
    refute ProcessLauncher.alive?(ref)
    RunWatcher.stop(spec.run_id)
  end

  test "a setsid template detaches with perl where setsid is missing", %{root: root} do
    script = write_sleep_script!(root)
    spec = spec(root, "run-perl-detach")

    assert {:ok, _watcher, "process:" <> rest = ref} =
             ProcessLauncher.start_process(spec,
               command: "RUN_ID={run_id} setsid #{script} {spec}",
               setsid_available: false,
               startup_check_ms: 200
             )

    [pid, _start] = String.split(rest, ":", parts: 2)
    # The runner leads its own process group, so stop can signal the group.
    {pgid, 0} = System.cmd("ps", ["-o", "pgid=", "-p", pid])
    assert String.trim(pgid) == pid
    assert :ok = ProcessLauncher.stop(ref)
    RunWatcher.stop(spec.run_id)

    # Left alone, the template runs as written: setsid where it exists.
    detected = spec(root, "run-setsid-detected")

    assert {:ok, _watcher, detected_ref} =
             ProcessLauncher.start_process(detected, command: "setsid #{script} {spec}", startup_check_ms: 200)

    assert :ok = ProcessLauncher.stop(detected_ref)
    RunWatcher.stop(detected.run_id)

    # Forcing setsid on a host without it fails the launch with the shell's error.
    forced = spec(root, "run-setsid-forced")

    case System.find_executable("setsid") do
      nil ->
        assert {:ok, watcher, _ref} =
                 ProcessLauncher.start_process(forced, command: "setsid #{script} {spec}", setsid_available: true, startup_check_ms: 300)

        assert assert_launch_failed(watcher) =~ "setsid"

      _setsid ->
        assert {:ok, _watcher, forced_ref} =
                 ProcessLauncher.start_process(forced, command: "setsid #{script} {spec}", setsid_available: true, startup_check_ms: 0)

        ProcessLauncher.stop(forced_ref)
        RunWatcher.stop(forced.run_id)
    end
  end

  test "a reference carries the start time, so a reused pid is never alive or stopped", %{root: root} do
    script = write_sleep_script!(root)
    spec = spec(root, "run-pid-reuse")

    assert {:ok, _watcher, "process:" <> rest = ref} =
             ProcessLauncher.start_process(spec, command: "#{script} {spec}", startup_check_ms: 0)

    [pid, start] = String.split(rest, ":", parts: 2)
    assert start =~ ~r/^\w{3}_\w{3}_+\d+_\d\d:\d\d:\d\d_\d{4}$/
    assert ProcessLauncher.alive?(ref)
    # A bare pid reference (no start time) is still checked by pid.
    assert ProcessLauncher.alive?("process:" <> pid)

    bin = Path.join(root, "ps-bin")
    File.mkdir_p!(bin)
    fake_ps = Path.join(bin, "ps")
    File.write!(fake_ps, "#!/bin/sh\necho 'S    Mon Jan  1 00:00:00 2001'\n")
    File.chmod!(fake_ps, 0o755)
    previous_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)

    try do
      # Another process now owns the pid: not alive, and stop leaves it be.
      refute ProcessLauncher.alive?(ref)
      assert :ok = ProcessLauncher.stop(ref, 50)
    after
      System.put_env("PATH", previous_path)
    end

    assert ProcessLauncher.alive?(ref)
    refute ProcessLauncher.alive?("process:#{pid}:Mon_Jan_1_00:00:00_2001")
    refute ProcessLauncher.alive?("process:abc:start")
    assert :ok = ProcessLauncher.stop("process:abc:start")
    assert :ok = ProcessLauncher.stop("process:" <> pid)
    refute ProcessLauncher.alive?(ref)
    RunWatcher.stop(spec.run_id)
  end

  test "a runner whose start time can't be read is never alive, so its watcher reports a failed launch", %{root: root} do
    # Short-lived: the failed launches don't stop it.
    script = Path.join(root, "short.sh")
    File.write!(script, "#!/bin/sh\nsleep 2\n")
    File.chmod!(script, 0o755)
    bin = Path.join(root, "bad-ps-bin")
    File.mkdir_p!(bin)
    fake_ps = Path.join(bin, "ps")
    previous_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)
    on_exit(fn -> System.put_env("PATH", previous_path) end)

    for {body, run_id} <- [{"#!/bin/sh\nexit 1\n", "run-ps-fails"}, {"#!/bin/sh\necho S\n", "run-ps-short"}] do
      File.write!(fake_ps, body)
      File.chmod!(fake_ps, 0o755)

      assert {:ok, watcher, "process:" <> rest} =
               ProcessLauncher.start_process(spec(root, run_id), command: "#{script} {spec}", startup_check_ms: 100)

      assert String.ends_with?(rest, ":gone")
      assert_launch_failed(watcher)
    end
  end

  test "a shell that does not print a pid is reported", %{root: root} do
    bin = Path.join(root, "pid-bin")
    File.mkdir_p!(bin)
    fake_sh = Path.join(bin, "sh")
    File.write!(fake_sh, "#!/bin/sh\nprintf 'not-a-pid\\n'\nexit 0\n")
    File.chmod!(fake_sh, 0o755)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)

    on_exit(fn ->
      if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH")
    end)

    spec = spec(root, "run-invalid-pid")
    assert {:error, {:invalid_pid_output, "run-invalid-pid", _output}} = ProcessLauncher.start_process(spec, command: "echo hi")
  end

  test "a process that ignores TERM is killed after the grace", %{root: root} do
    script = Path.join(root, "ignore-term.sh")

    File.write!(script, """
    #!/bin/sh
    trap '' TERM
    while :; do sleep 1; done
    """)

    File.chmod!(script, 0o755)

    kill_bin = Path.join(root, "kill-bin")
    File.mkdir_p!(kill_bin)
    real_kill = System.find_executable("kill")
    fake_kill = Path.join(kill_bin, "kill")

    File.write!(fake_kill, """
    #!/bin/sh
    case "$1" in
      -0) exec '#{real_kill}' "$@" ;;
      -TERM) exit 0 ;;
      -KILL) exec '#{real_kill}' "$@" ;;
    esac
    exit 0
    """)

    File.chmod!(fake_kill, 0o755)
    previous_path = System.get_env("PATH")
    System.put_env("PATH", kill_bin <> ":" <> previous_path)

    on_exit(fn ->
      if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH")
    end)

    spec = spec(root, "run-ignore-term")

    assert {:ok, _watcher, ref} =
             ProcessLauncher.start_process(spec,
               command: "#{script} {spec}",
               poll_interval_ms: 20,
               lost_grace_ms: 200
             )

    assert eventually(fn -> ProcessLauncher.alive?(ref) end)
    assert :ok = ProcessLauncher.stop(ref, 20)
    refute ProcessLauncher.alive?(ref)
    RunWatcher.stop(spec.run_id)
  end

  test "references from another kind of launcher are never alive", %{root: root} do
    assert ProcessLauncher.alive?(nil) == false
    assert ProcessLauncher.alive?("local:anything") == false
    assert ProcessLauncher.alive?("process:0") == false
    assert ProcessLauncher.alive?("process:") == false
    assert ProcessLauncher.alive?("systemd:") == false
    refute ProcessLauncher.command_template([]) == ""
    assert ProcessLauncher.symphony_binary(symphony: "/bin/symphony") == "/bin/symphony"
    assert ProcessLauncher.symphony_binary(symphony: nil) == nil
    assert RunLauncher.Process == ProcessLauncher
    _ = root
  end

  test "stop returns after its timeout when KILL does not end the process", %{root: root} do
    script = Path.join(root, "unkillable.sh")
    File.write!(script, "#!/bin/sh\ntrap '' TERM KILL\nwhile :; do sleep 1; done\n")
    File.chmod!(script, 0o755)

    kill_bin = Path.join(root, "unkillable-kill-bin")
    File.mkdir_p!(kill_bin)
    real_kill = System.find_executable("kill")
    fake_kill = Path.join(kill_bin, "kill")
    File.write!(fake_kill, "#!/bin/sh\nif [ \"$1\" = \"-0\" ]; then exec '#{real_kill}' \"$@\"; fi\nexit 0\n")
    File.chmod!(fake_kill, 0o755)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", kill_bin <> ":" <> previous_path)

    on_exit(fn ->
      if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH")
    end)

    spec = spec(root, "run-unkillable")

    assert {:ok, _watcher, ref} =
             ProcessLauncher.start_process(spec,
               command: "#{script} {spec}",
               poll_interval_ms: 20,
               lost_grace_ms: 200
             )

    assert eventually(fn -> ProcessLauncher.alive?(ref) end)
    assert :ok = ProcessLauncher.stop(ref, 20)
    assert ProcessLauncher.alive?(ref)

    System.put_env("PATH", previous_path)
    assert :ok = ProcessLauncher.stop(ref, 1_000)
    refute ProcessLauncher.alive?(ref)
    RunWatcher.stop(spec.run_id)
  end

  test "systemd references use the unit name for liveness and stop", %{root: root} do
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    state = Path.join(root, "systemd-state")
    File.mkdir_p!(state)
    write_fake_systemd!(bin, state)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)

    on_exit(fn ->
      if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH")
    end)

    spec = spec(root, "run-systemd")
    command = "systemd-run --user --unit=symphony-run-#{spec.run_id} --collect {symphony} runner {spec} --flag"

    assert {:ok, _watcher, "systemd:" <> unit} =
             ProcessLauncher.start_process(spec,
               command: command,
               symphony: "/bin/symphony",
               poll_interval_ms: 20,
               lost_grace_ms: 200
             )

    assert unit == "symphony-run-#{spec.run_id}"

    # `{run_id}` is shell-quoted in the command, and the unit name still parses.
    placeholder_spec = spec(root, "run-systemd-placeholder")

    assert {:ok, _placeholder_watcher, "systemd:symphony-run-run-systemd-placeholder"} =
             ProcessLauncher.start_process(placeholder_spec,
               command: "systemd-run --user --unit=symphony-run-{run_id} {symphony} runner {spec}",
               symphony: "/bin/symphony"
             )

    RunWatcher.stop(placeholder_spec.run_id)
    assert ProcessLauncher.alive?("systemd:" <> unit)
    assert :ok = ProcessLauncher.stop("systemd:" <> unit)
    refute ProcessLauncher.alive?("systemd:" <> unit)
    RunWatcher.stop(spec.run_id)

    for {quoted, run_id} <- [{"'", "run-systemd-single"}, {"\"", "run-systemd-double"}] do
      quoted_spec = spec(root, run_id)
      quoted_unit = "quoted-#{run_id}"
      command = "systemd-run --user --unit=#{quoted}#{quoted_unit}#{quoted} {symphony} runner {spec}"

      assert {:ok, quoted_watcher, "systemd:" <> ^quoted_unit} =
               ProcessLauncher.start_process(quoted_spec, command: command, symphony: "/bin/symphony")

      Process.monitor(quoted_watcher)
      RunWatcher.stop(quoted_spec.run_id)
    end

    # A watcher whose unit is inactive sees the process go away.
    assert {:ok, inactive_watcher, "systemd:" <> inactive_unit} =
             ProcessLauncher.start_process(spec,
               command: command,
               symphony: "/bin/symphony",
               poll_interval_ms: 20,
               lost_grace_ms: 200
             )

    monitor = Process.monitor(inactive_watcher)
    assert :ok = ProcessLauncher.stop("systemd:" <> inactive_unit)
    assert_receive {:DOWN, ^monitor, :process, ^inactive_watcher, _reason}, 3_000
  end

  test "a broken config falls back to the documented runner command" do
    previous_path = SymphonyElixir.Workflow.workflow_file_path()
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    try do
      SymphonyElixir.Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))
      assert ProcessLauncher.command_template() == SymphonyElixir.Config.default_runner_command()
    after
      SymphonyElixir.Workflow.set_workflow_file_path(previous_path)
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
    end
  end

  test "the default command template selects a real launcher" do
    assert ProcessLauncher.command_template() =~ "{symphony}"
    assert ProcessLauncher.command_template([]) =~ "runner {spec}"
    assert ProcessLauncher.command_template(command: "custom {spec}") == "custom {spec}"
    assert ProcessLauncher.symphony_binary() == ProcessLauncher.symphony_binary([])

    previous_path = SymphonyElixir.Workflow.workflow_file_path()
    SymphonyElixir.Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    try do
      assert ProcessLauncher.command_template() == SymphonyElixir.Config.default_runner_command()
    after
      SymphonyElixir.Workflow.set_workflow_file_path(previous_path)
    end
  end

  defp assert_launch_failed(watcher) do
    monitor = Process.monitor(watcher)
    assert_receive {:DOWN, ^monitor, :process, ^watcher, {:launch_failed, tail}}, 5_000
    tail
  end

  defp spec(_root, run_id) do
    %RunSpec{
      run_id: run_id,
      epoch: 1,
      attempt: 0,
      issue: %Issue{id: "issue-#{run_id}", identifier: "MT-P-1", title: "Process"},
      backend: "claude",
      route: %{backend: "claude", effort: nil},
      controller_url: "http://127.0.0.1:1",
      token: "token"
    }
  end

  defp write_sleep_script!(root) do
    script = Path.join(root, "run.sh")

    File.write!(script, """
    #!/bin/sh
    printf '%s' "$1" > '#{Path.join(root, "started")}'
    exec sleep 1000
    """)

    File.chmod!(script, 0o755)
    script
  end

  defp write_fake_systemd!(bin, state) do
    systemd_run = Path.join(bin, "systemd-run")

    File.write!(systemd_run, """
    #!/bin/sh
    unit=""
    previous=""
    for arg in "$@"; do
      case "$arg" in
        --unit=*) unit="${arg#--unit=}" ;;
      esac
      if [ "$previous" = "--unit" ]; then unit="$arg"; fi
      previous="$arg"
    done
    if [ -n "$unit" ]; then
      touch '#{state}/'"$unit".active
      printf '%s' "$unit" > '#{state}/unit'
    fi
    exit 0
    """)

    systemctl = Path.join(bin, "systemctl")

    File.write!(systemctl, """
    #!/bin/sh
    if [ "$1" = "--user" ]; then shift; fi
    case "$1" in
      is-active)
        if [ -f '#{state}/'"$2".active ]; then echo active; exit 0; else echo inactive; exit 3; fi
        ;;
      stop)
        rm -f '#{state}/'"$2".active
        exit 0
        ;;
    esac
    exit 0
    """)

    File.chmod!(systemd_run, 0o755)
    File.chmod!(systemctl, 0o755)
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
