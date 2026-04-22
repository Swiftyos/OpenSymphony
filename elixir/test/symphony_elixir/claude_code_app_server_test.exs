defmodule SymphonyElixir.ClaudeCodeAppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.Tooling

  test "claude backend streams assistant updates and completes a turn" do
    test_root = temp_root!("run")
    trace_env = "SYMP_TEST_CLAUDE_TRACE_#{System.unique_integer([:positive])}"
    scenario_env = "SYMP_TEST_CLAUDE_SCENARIO_#{System.unique_integer([:positive])}"
    previous_trace = System.get_env(trace_env)
    previous_scenario = System.get_env(scenario_env)

    on_exit(fn ->
      restore_env(trace_env, previous_trace)
      restore_env(scenario_env, previous_scenario)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CLAUDE-101")
      trace_file = Path.join(test_root, "claude.trace")
      launcher = write_fake_claude_launcher!(test_root, trace_env, scenario_env)

      File.mkdir_p!(workspace)
      System.put_env(trace_env, trace_file)
      System.put_env(scenario_env, "success")

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        workspace_root: workspace_root,
        claude_command: launcher,
        claude_model: "sonnet",
        claude_permission_mode: "dontAsk",
        providers_openrouter_api_key: "openrouter-claude-token"
      )

      assert :ok = Tooling.bootstrap_workspace(workspace)

      parent = self()

      assert {:ok, result} =
               AppServer.run(
                 workspace,
                 "Ship the change",
                 issue_fixture("MT-CLAUDE-101", "Ship the change"),
                 effort: "max",
                 on_message: &send(parent, {:agent_message, &1})
               )

      assert result.session_id == result.thread_id
      assert result.turn_id == "result-1"

      assert_receive {:agent_message, %{event: :turn_started, session_id: session_id}}, 1_000

      assert_receive {:agent_message,
                      %{
                        event: "message.part.updated",
                        session_id: ^session_id,
                        usage: %{"input" => 12, "output" => 4, "reasoning" => 3},
                        payload: %{
                          "payload" => %{
                            "type" => "message.part.updated",
                            "properties" => %{
                              "part" => %{
                                "sessionID" => ^session_id,
                                "type" => "text",
                                "text" => "Inspecting repository"
                              }
                            }
                          }
                        }
                      }},
                     1_000

      assert_receive {:agent_message,
                      %{
                        event: "message.part.updated",
                        session_id: ^session_id,
                        payload: %{
                          "payload" => %{
                            "properties" => %{
                              "part" => %{
                                "type" => "reasoning",
                                "text" => "Considering the diff"
                              }
                            }
                          }
                        }
                      }},
                     1_000

      assert_receive {:agent_message,
                      %{
                        event: "message.part.updated",
                        session_id: ^session_id,
                        payload: %{
                          "payload" => %{
                            "properties" => %{
                              "part" => %{
                                "type" => "tool",
                                "tool" => "linear_graphql",
                                "state" => %{"status" => "running"}
                              }
                            }
                          }
                        }
                      }},
                     1_000

      assert_receive {:agent_message,
                      %{
                        event: :turn_completed,
                        session_id: ^session_id,
                        usage: %{"input" => 12, "output" => 4, "reasoning" => 3, "total" => 19}
                      }},
                     1_000

      trace = File.read!(trace_file)
      assert trace =~ "ARGV:"
      assert trace =~ "--input-format stream-json"
      assert trace =~ "--mcp-config .symphony/claude/mcp.json"
      assert trace =~ "--permission-mode dontAsk"
      assert trace =~ "--model sonnet"
      assert trace =~ "--effort max"
      assert trace =~ "ENV:SYMPHONY_LINEAR_API_KEY=token"
      assert trace =~ "ENV:OPENROUTER_API_KEY=openrouter-claude-token"
      assert trace =~ "\"content\":\"Ship the change\""
    after
      File.rm_rf(test_root)
    end
  end

  test "claude backend reuses a long-lived session across turns" do
    test_root = temp_root!("multi-turn")
    trace_env = "SYMP_TEST_CLAUDE_TRACE_#{System.unique_integer([:positive])}"
    scenario_env = "SYMP_TEST_CLAUDE_SCENARIO_#{System.unique_integer([:positive])}"
    previous_trace = System.get_env(trace_env)
    previous_scenario = System.get_env(scenario_env)

    on_exit(fn ->
      restore_env(trace_env, previous_trace)
      restore_env(scenario_env, previous_scenario)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CLAUDE-102")
      trace_file = Path.join(test_root, "claude-multi.trace")
      launcher = write_fake_claude_launcher!(test_root, trace_env, scenario_env)

      File.mkdir_p!(workspace)
      System.put_env(trace_env, trace_file)
      System.put_env(scenario_env, "success")

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        workspace_root: workspace_root,
        claude_command: launcher
      )

      assert :ok = Tooling.bootstrap_workspace(workspace)
      assert {:ok, session} = AppServer.start_session(workspace)

      try do
        assert {:ok, first_result} =
                 AppServer.run_turn(session, "First turn", issue_fixture("MT-CLAUDE-102", "First turn"))

        refute :erlang.port_info(session.port) == :undefined

        assert {:ok, second_result} =
                 AppServer.run_turn(session, "Second turn", issue_fixture("MT-CLAUDE-102", "Second turn"))

        assert first_result.session_id == session.session_id
        assert second_result.session_id == session.session_id
        assert first_result.turn_id == "result-1"
        assert second_result.turn_id == "result-2"

        trace = File.read!(trace_file)
        assert trace =~ "\"content\":\"First turn\""
        assert trace =~ "\"content\":\"Second turn\""
      after
        AppServer.stop_session(session)
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "claude backend surfaces result errors" do
    test_root = temp_root!("error")
    trace_env = "SYMP_TEST_CLAUDE_TRACE_#{System.unique_integer([:positive])}"
    scenario_env = "SYMP_TEST_CLAUDE_SCENARIO_#{System.unique_integer([:positive])}"
    previous_trace = System.get_env(trace_env)
    previous_scenario = System.get_env(scenario_env)

    on_exit(fn ->
      restore_env(trace_env, previous_trace)
      restore_env(scenario_env, previous_scenario)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CLAUDE-103")
      launcher = write_fake_claude_launcher!(test_root, trace_env, scenario_env)

      File.mkdir_p!(workspace)
      System.put_env(trace_env, Path.join(test_root, "claude-error.trace"))
      System.put_env(scenario_env, "error")

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        workspace_root: workspace_root,
        claude_command: launcher
      )

      assert :ok = Tooling.bootstrap_workspace(workspace)

      parent = self()

      assert {:error, {:claude_result_error, %{"subtype" => "error", "is_error" => true} = payload}} =
               AppServer.run(
                 workspace,
                 "Hit an execution error",
                 issue_fixture("MT-CLAUDE-103", "Execution error"),
                 on_message: &send(parent, {:agent_message, &1})
               )

      assert payload["message"] == "blocked"
      assert_receive {:agent_message, %{event: :turn_started}}, 1_000

      assert_receive {:agent_message, %{event: :turn_ended_with_error, reason: {:claude_result_error, %{"subtype" => "error"}}}},
                     1_000
    after
      File.rm_rf(test_root)
    end
  end

  test "claude backend closes the session on stall timeout" do
    test_root = temp_root!("stall-timeout")
    trace_env = "SYMP_TEST_CLAUDE_TRACE_#{System.unique_integer([:positive])}"
    scenario_env = "SYMP_TEST_CLAUDE_SCENARIO_#{System.unique_integer([:positive])}"
    previous_trace = System.get_env(trace_env)
    previous_scenario = System.get_env(scenario_env)

    on_exit(fn ->
      restore_env(trace_env, previous_trace)
      restore_env(scenario_env, previous_scenario)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CLAUDE-104")
      launcher = write_fake_claude_launcher!(test_root, trace_env, scenario_env)

      File.mkdir_p!(workspace)
      System.put_env(trace_env, Path.join(test_root, "claude-stall.trace"))
      System.put_env(scenario_env, "stall")

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        workspace_root: workspace_root,
        claude_command: launcher,
        claude_turn_timeout_ms: 1_000,
        claude_read_timeout_ms: 2_000,
        claude_stall_timeout_ms: 50
      )

      assert :ok = Tooling.bootstrap_workspace(workspace)
      assert {:ok, session} = AppServer.start_session(workspace)

      try do
        assert {:error, :stall_timeout} =
                 AppServer.run_turn(session, "Wait too long", issue_fixture("MT-CLAUDE-104", "Stall timeout"))

        wait_for_port_closed!(session.port)
      after
        AppServer.stop_session(session)
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "claude backend kills the OS process when stopping a session" do
    test_root = temp_root!("stop-session-kills-process")
    trace_env = "SYMP_TEST_CLAUDE_TRACE_#{System.unique_integer([:positive])}"
    scenario_env = "SYMP_TEST_CLAUDE_SCENARIO_#{System.unique_integer([:positive])}"
    previous_trace = System.get_env(trace_env)
    previous_scenario = System.get_env(scenario_env)

    on_exit(fn ->
      restore_env(trace_env, previous_trace)
      restore_env(scenario_env, previous_scenario)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CLAUDE-105")
      launcher = write_fake_claude_launcher!(test_root, trace_env, scenario_env)

      File.mkdir_p!(workspace)
      System.put_env(trace_env, Path.join(test_root, "claude-stop.trace"))
      System.put_env(scenario_env, "ignore_term")

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        workspace_root: workspace_root,
        claude_command: launcher
      )

      assert :ok = Tooling.bootstrap_workspace(workspace)
      assert {:ok, session} = AppServer.start_session(workspace)
      assert {:os_pid, os_pid} = :erlang.port_info(session.port, :os_pid)
      assert os_process_alive?(os_pid)

      assert :ok = AppServer.stop_session(session)

      wait_for_port_closed!(session.port)
      wait_for_os_process_exit!(os_pid)
    after
      File.rm_rf(test_root)
    end
  end

  test "claude backend builds remote ssh launch commands for worker hosts" do
    test_root = temp_root!("remote-ssh")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
    end)

    try do
      workspace = "/remote/workspaces/MT-CLAUDE-REMOTE"
      install_fake_ssh!(test_root, trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        workspace_root: "/remote/workspaces",
        claude_command: "fake-remote-claude",
        claude_model: "haiku",
        claude_permission_mode: "dontAsk"
      )

      assert {:ok, result} =
               AppServer.run(
                 workspace,
                 "Run remote worker",
                 issue_fixture("MT-CLAUDE-REMOTE", "Run remote worker"),
                 worker_host: "worker-01:2200"
               )

      assert result.turn_id == "remote-result-1"

      trace = File.read!(trace_file)
      assert trace =~ "ARGV:-T -p 2200 worker-01 bash -lc"
      assert trace =~ "cd "
      assert trace =~ "/remote/workspaces/MT-CLAUDE-REMOTE"
      assert trace =~ "SYMPHONY_LINEAR_API_KEY"
      assert trace =~ "SYMPHONY_LINEAR_ENDPOINT"
      assert trace =~ "https://api.linear.app/graphql"
      assert trace =~ "exec fake-remote-claude -p --output-format stream-json --input-format stream-json --verbose"
      assert trace =~ ".symphony/claude/mcp.json"
      assert trace =~ "--permission-mode "
      assert trace =~ "dontAsk"
      assert trace =~ "--model "
      assert trace =~ "haiku"
      assert trace =~ "JSON:{\"message\":{\"content\":\"Run remote worker\""
    after
      File.rm_rf(test_root)
    end
  end

  test "claude backend injects telemetry env vars when telemetry is enabled" do
    test_root = temp_root!("telemetry")
    trace_env = "SYMP_TEST_CLAUDE_TRACE_#{System.unique_integer([:positive])}"
    scenario_env = "SYMP_TEST_CLAUDE_SCENARIO_#{System.unique_integer([:positive])}"
    previous_trace = System.get_env(trace_env)
    previous_scenario = System.get_env(scenario_env)

    on_exit(fn ->
      restore_env(trace_env, previous_trace)
      restore_env(scenario_env, previous_scenario)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CLAUDE-TEL")
      trace_file = Path.join(test_root, "claude-telemetry.trace")
      launcher = write_fake_claude_launcher!(test_root, trace_env, scenario_env)

      File.mkdir_p!(workspace)
      System.put_env(trace_env, trace_file)
      System.put_env(scenario_env, "success")

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        workspace_root: workspace_root,
        claude_command: launcher,
        telemetry_enabled: true,
        telemetry_otlp_endpoint: "http://localhost:11338",
        telemetry_otlp_protocol: "grpc",
        telemetry_include_traces: true,
        telemetry_include_metrics: true,
        telemetry_include_logs: true,
        telemetry_resource_attributes: %{"environment" => "test"},
        instance_name: "test-instance"
      )

      assert :ok = Tooling.bootstrap_workspace(workspace)

      assert {:ok, _result} =
               AppServer.run(
                 workspace,
                 "Telemetry test",
                 issue_fixture("MT-CLAUDE-TEL", "Telemetry test")
               )

      trace = File.read!(trace_file)
      assert trace =~ "ENV:CLAUDE_CODE_ENABLE_TELEMETRY=1"
      assert trace =~ "ENV:CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1"
      assert trace =~ "ENV:OTEL_METRICS_EXPORTER=otlp"
      assert trace =~ "ENV:OTEL_LOGS_EXPORTER=otlp"
      assert trace =~ "ENV:OTEL_TRACES_EXPORTER=otlp"
      assert trace =~ "ENV:OTEL_EXPORTER_OTLP_PROTOCOL=grpc"
      assert trace =~ "ENV:OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:11338"
      assert trace =~ "ENV:OTEL_RESOURCE_ATTRIBUTES="
      assert trace =~ "linear.issue.id=issue-MT-CLAUDE-TEL"
      assert trace =~ "linear.issue.identifier=MT-CLAUDE-TEL"
      assert trace =~ "symphony.backend=claude"
      assert trace =~ "symphony.instance=test-instance"
      assert trace =~ "environment=test"
    after
      File.rm_rf(test_root)
    end
  end

  defp issue_fixture(identifier, title) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: title,
      description: "Exercise the Claude Code app server test harness",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: ["backend"]
    }
  end

  defp temp_root!(suffix) do
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-claude-app-server-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp write_fake_claude_launcher!(test_root, trace_env, scenario_env) do
    launcher = Path.join(test_root, "fake-claude-launcher.sh")
    File.mkdir_p!(test_root)

    File.write!(
      launcher,
      """
      #!/bin/sh
      trace_file="${#{trace_env}:-/tmp/fake-claude.trace}"
      scenario="${#{scenario_env}:-success}"
      session_id=""
      previous_arg=""

      for arg in "$@"; do
        if [ "$previous_arg" = "--session-id" ]; then
          session_id="$arg"
        fi

        previous_arg="$arg"
      done

      if [ -z "$session_id" ]; then
        session_id="session-fallback"
      fi

      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      if [ "$scenario" = "ignore_term" ]; then
        printf 'PID:%s\\n' "$$" >> "$trace_file"
        trap '' TERM

        while true; do
          sleep 1
        done
      fi

      if [ -n "${SYMPHONY_LINEAR_API_KEY:-}" ]; then
        printf 'ENV:SYMPHONY_LINEAR_API_KEY=%s\\n' "$SYMPHONY_LINEAR_API_KEY" >> "$trace_file"
      fi

      if [ -n "${SYMPHONY_LINEAR_ENDPOINT:-}" ]; then
        printf 'ENV:SYMPHONY_LINEAR_ENDPOINT=%s\\n' "$SYMPHONY_LINEAR_ENDPOINT" >> "$trace_file"
      fi

      if [ -n "${OPENROUTER_API_KEY:-}" ]; then
        printf 'ENV:OPENROUTER_API_KEY=%s\n' "$OPENROUTER_API_KEY" >> "$trace_file"
      fi

      env | grep -E '^(CLAUDE_CODE_|OTEL_)' | while IFS= read -r line; do
        var_name=$(printf '%s' "$line" | cut -d= -f1)
        var_value=$(printf '%s' "$line" | cut -d= -f2-)
        printf 'ENV:%s=%s\n' "$var_name" "$var_value" >> "$trace_file"
      done

      turn=0

      while IFS= read -r line; do
        turn=$((turn + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$scenario" in
          success)
            printf '%s\\n' "{\\"type\\":\\"system\\",\\"subtype\\":\\"init\\",\\"session_id\\":\\"$session_id\\"}"
            printf '%s\\n' "{\\"type\\":\\"assistant\\",\\"message\\":{\\"content\\":[{\\"type\\":\\"text\\",\\"text\\":\\"Inspecting repository\\"},{\\"type\\":\\"thinking\\",\\"text\\":\\"Considering the diff\\"},{\\"type\\":\\"tool_use\\",\\"name\\":\\"linear_graphql\\"}],\\"usage\\":{\\"input\\":12,\\"output\\":4,\\"reasoning\\":3}}}"
            printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"session_id\\":\\"$session_id\\",\\"uuid\\":\\"result-$turn\\",\\"usage\\":{\\"input\\":12,\\"output\\":4,\\"reasoning\\":3,\\"total\\":19}}"
            ;;
          error)
            printf '%s\\n' "{\\"type\\":\\"system\\",\\"subtype\\":\\"init\\",\\"session_id\\":\\"$session_id\\"}"
            printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"error\\",\\"session_id\\":\\"$session_id\\",\\"is_error\\":true,\\"message\\":\\"blocked\\"}"
            ;;
          stall)
            printf '%s\\n' "{\\"type\\":\\"system\\",\\"subtype\\":\\"init\\",\\"session_id\\":\\"$session_id\\"}"
            sleep 1
            ;;
          *)
            printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"error\\",\\"session_id\\":\\"$session_id\\",\\"is_error\\":true,\\"message\\":\\"unknown scenario\\"}"
            exit 0
            ;;
        esac
      done
      """
    )

    File.chmod!(launcher, 0o755)
    launcher
  end

  defp install_fake_ssh!(test_root, trace_file) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")

    File.mkdir_p!(fake_bin_dir)

    File.write!(
      fake_ssh,
      """
      #!/bin/sh
      printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"

      last_arg=""

      for arg in "$@"; do
        last_arg="$arg"
      done

      case "$last_arg" in
        *"--input-format stream-json"*)
          while IFS= read -r line; do
            printf 'JSON:%s\\n' "$line" >> "#{trace_file}"
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Remote worker"}],"usage":{"input":5,"output":2,"reasoning":1}}}'
            printf '%s\\n' '{"type":"result","subtype":"success","uuid":"remote-result-1","usage":{"input":5,"output":2,"reasoning":1,"total":8}}'
            exit 0
          done
          ;;
        *)
          exit 0
          ;;
      esac
      """
    )

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end

  defp wait_for_port_closed!(port, attempts \\ 40)
  defp wait_for_port_closed!(_port, 0), do: flunk("timed out waiting for Claude session port to close")

  defp wait_for_port_closed!(port, attempts) do
    if :erlang.port_info(port) == :undefined do
      :ok
    else
      Process.sleep(25)
      wait_for_port_closed!(port, attempts - 1)
    end
  end

  defp wait_for_os_process_exit!(os_pid, attempts \\ 80)
  defp wait_for_os_process_exit!(os_pid, 0), do: flunk("timed out waiting for OS process #{os_pid} to exit")

  defp wait_for_os_process_exit!(os_pid, attempts) do
    if os_process_alive?(os_pid) do
      Process.sleep(25)
      wait_for_os_process_exit!(os_pid, attempts - 1)
    else
      :ok
    end
  end

  defp os_process_alive?(os_pid) when is_integer(os_pid) and os_pid > 0 do
    case System.cmd("kill", ["-0", "--", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp os_process_alive?(_os_pid), do: false
end
