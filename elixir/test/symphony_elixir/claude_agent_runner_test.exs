defmodule SymphonyElixir.ClaudeAgentRunnerTest do
  use SymphonyElixir.TestSupport

  test "agent runner uses Claude through the generic update path and continuation prompt" do
    test_root = temp_root!("continuation")
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
      trace_file = Path.join(test_root, "claude-runner.trace")
      launcher = write_fake_claude_launcher!(test_root, trace_env, scenario_env)

      File.mkdir_p!(workspace_root)
      System.put_env(trace_env, trace_file)
      System.put_env(scenario_env, "success")

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        workspace_root: workspace_root,
        hook_after_create: "printf '# test\\n' > README.md",
        claude_command: launcher,
        max_turns: 3
      )

      issue = issue_fixture("issue-claude-runner", "MT-CLAUDE-201", "Continue until done")
      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:claude_agent_turn_fetch_count, 0) + 1
        Process.put(:claude_agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok, [%{issue | state: state}]}
      end

      assert :ok = AgentRunner.run(issue, self(), issue_state_fetcher: state_fetcher)

      assert_receive {:worker_runtime_info, "issue-claude-runner", %{workspace_path: workspace_path}}, 1_000
      assert File.exists?(Path.join(workspace_path, ".symphony/claude/mcp.json"))

      assert_receive {:issue_state_fetch, 1}, 1_000
      assert_receive {:issue_state_fetch, 2}, 1_000

      assert_receive {:agent_worker_update, "issue-claude-runner", %{event: :turn_started, timestamp: %DateTime{}, session_id: session_id}},
                     1_000

      assert_receive {:agent_worker_update, "issue-claude-runner", %{event: :turn_completed, timestamp: %DateTime{}, session_id: ^session_id}},
                     1_000

      assert_receive {:agent_worker_update, "issue-claude-runner", %{event: :turn_started, timestamp: %DateTime{}, session_id: ^session_id}},
                     1_000

      assert_receive {:agent_worker_update, "issue-claude-runner", %{event: :turn_completed, timestamp: %DateTime{}, session_id: ^session_id}},
                     1_000

      trace = File.read!(trace_file)
      assert trace =~ "\"content\":\"You are an agent for this repository."
      assert trace =~ "\"content\":\"Continuation guidance:\\n\\n- The previous agent turn completed normally, but the Linear issue is still in an active state."
      assert trace =~ "continuation turn #2 of 3"
    after
      Process.delete(:claude_agent_turn_fetch_count)
      File.rm_rf(test_root)
    end
  end

  defp issue_fixture(id, identifier, title) do
    %Issue{
      id: id,
      identifier: identifier,
      title: title,
      description: "Exercise the Claude agent runner test harness",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: ["backend"]
    }
  end

  defp temp_root!(suffix) do
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-claude-agent-runner-#{suffix}-#{System.unique_integer([:positive])}"
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
      turn=0

      while IFS= read -r line; do
        turn=$((turn + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$scenario" in
          success)
            printf '%s\\n' "{\\"type\\":\\"system\\",\\"subtype\\":\\"init\\",\\"session_id\\":\\"$session_id\\"}"
            printf '%s\\n' "{\\"type\\":\\"assistant\\",\\"message\\":{\\"content\\":[{\\"type\\":\\"text\\",\\"text\\":\\"Runner turn $turn\\"}],\\"usage\\":{\\"input\\":8,\\"output\\":2,\\"reasoning\\":1}}}"
            printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"session_id\\":\\"$session_id\\",\\"uuid\\":\\"runner-result-$turn\\",\\"usage\\":{\\"input\\":8,\\"output\\":2,\\"reasoning\\":1,\\"total\\":11}}"
            ;;
          *)
            printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"error\\",\\"session_id\\":\\"$session_id\\",\\"is_error\\":true,\\"message\\":\\"unexpected scenario\\"}"
            exit 0
            ;;
        esac
      done
      """
    )

    File.chmod!(launcher, 0o755)
    launcher
  end
end
