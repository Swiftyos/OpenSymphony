defmodule SymphonyElixir.ProcessLauncherE2ETest do
  use SymphonyElixir.TestSupport

  @moduletag :e2e_process
  @moduletag timeout: 120_000

  alias SymphonyElixir.HttpServer
  alias SymphonyElixir.RunnerTestSupport, as: Support
  alias SymphonyElixir.RunRegistry
  alias SymphonyElixir.RunWatcher

  setup_all do
    cwd = File.cwd!()

    case System.cmd("mix", ["build"], cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, escript: Path.join(cwd, "bin/symphony"), output: output}
      {output, status} -> flunk("mix build failed (#{status}):\n#{output}")
    end
  end

  setup do
    root = Support.temp_root!("process-e2e")
    Support.setup_runs!(root)
    %{root: root}
  end

  test "a runner survives a controller restart and is adopted", %{root: root, escript: escript} do
    issue = Support.issue_fixture("issue-e2e-process", "MT-E2E-PROCESS")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    marker = Path.join(root, "agent-started")
    fake_agent = write_slow_fake_claude!(root, marker)
    config_path = Workflow.workflow_file_path()
    # `{symphony}` would be `mix` under `mix test`, so the escript is named
    # directly; the required placeholders ride along as unused assignments.
    # `setsid` becomes the perl detach on a host without it (macOS).
    command =
      "SYMPHONY_RUN_ID={run_id} SYMPHONY_UNUSED={symphony} setsid #{escript} runner {spec} #{config_path} --i-understand-that-this-will-be-running-without-the-usual-guardrails"

    write_workflow_file!(config_path,
      tracker_kind: "memory",
      agent_backend: "claude",
      agent_launcher: "process",
      agent_runner_command: command,
      workspace_root: Path.join(root, "workspaces"),
      claude_command: fake_agent,
      max_turns: 1,
      poll_interval_ms: 100
    )

    name = Module.concat(__MODULE__, "Orchestrator")
    {:ok, orchestrator} = Orchestrator.start_link(name: name)
    {:ok, endpoint} = HttpServer.start_link(port: 0, orchestrator: name)

    on_exit(fn ->
      # Linked to the test process, they may already be shutting down.
      for pid <- [orchestrator, endpoint], Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    assert eventually(fn -> File.exists?(marker) end, 100)
    state = :sys.get_state(orchestrator)
    assert %{run_id: run_id, epoch: epoch, launcher: SymphonyElixir.RunLauncher.Process, run_ref: ref} = state.running[issue.id]
    assert is_binary(run_id)
    assert is_integer(epoch)

    # Restart the controller state while the runner keeps working. In a real
    # deploy the BEAM and its watchers go away together; stopping the
    # watchers here reproduces that.
    GenServer.stop(orchestrator)
    RunWatcher.stop(run_id)
    assert %{run_id: ^run_id} = RunRegistry.load()[issue.id]

    {:ok, orchestrator} = Orchestrator.start_link(name: name)

    assert eventually(fn -> Map.has_key?(:sys.get_state(orchestrator).running, issue.id) end, 100)
    adopted = :sys.get_state(orchestrator).running[issue.id]
    assert adopted.run_id == run_id
    assert adopted.epoch == epoch
    assert adopted.launcher == SymphonyElixir.RunLauncher.Process
    assert adopted.run_ref == ref
    assert :sys.get_state(orchestrator).retry_attempts == %{}

    assert eventually(fn -> not Map.has_key?(:sys.get_state(orchestrator).running, issue.id) end, 300)
    state = :sys.get_state(orchestrator)
    assert %{attempt: 1, identifier: "MT-E2E-PROCESS"} = state.retry_attempts[issue.id]
    assert RunRegistry.load() == %{}

    GenServer.stop(orchestrator)
    RunRegistry.delete(issue.id)
  end

  defp write_slow_fake_claude!(root, marker) do
    launcher = Path.join(root, "slow-claude.sh")

    File.write!(launcher, """
    #!/bin/sh
    printf 'started' > '#{marker}'
    session_id=""
    previous_arg=""
    for arg in "$@"; do
      if [ "$previous_arg" = "--session-id" ]; then session_id="$arg"; fi
      previous_arg="$arg"
    done
    sleep 4
    while IFS= read -r line; do
      printf '%s\\n' "{\\"type\\":\\"system\\",\\"subtype\\":\\"init\\",\\"session_id\\":\\"$session_id\\"}"
      printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"session_id\\":\\"$session_id\\",\\"uuid\\":\\"e2e-result\\"}"
    done
    """)

    File.chmod!(launcher, 0o755)
    launcher
  end

  defp eventually(fun, attempts) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(100)
        eventually(fun, attempts - 1)
    end
  end
end
