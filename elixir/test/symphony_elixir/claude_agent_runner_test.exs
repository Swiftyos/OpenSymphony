defmodule SymphonyElixir.ClaudeAgentRunnerTest do
  use SymphonyElixir.TestSupport

  # Real git/process/HTTP integration; excluded by `make test-fast`.
  @moduletag :slow

  alias SymphonyElixir.FactoryControls

  setup do
    FactoryControls.reset()
    on_exit(&FactoryControls.reset/0)
    :ok
  end

  test "a pick-up into the same backend continues with the new stage's effort" do
    %{issue: issue, trace_file: trace_file} = runner_setup!("success", 1)

    {:ok, _} = FactoryControls.put("todo", "effort", "low")
    {:ok, _} = FactoryControls.put("implement", "effort", "high")

    issue = %{issue | state: "Todo", labels: []}
    issue_id = issue.id

    assert :ok = AgentRunner.run(issue, self(), issue_state_fetcher: fn _ -> {:ok, [%{issue | state: "Done"}]} end)

    assert_receive {:worker_runtime_info, ^issue_id, %{backend: "claude", effort: "high"}}, 1_000

    argv = trace_file |> File.read!() |> String.split("\n", trim: true) |> Enum.find(&String.starts_with?(&1, "ARGV:"))
    assert argv =~ "--effort high"
    refute argv =~ "--effort low"
  end

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

      assert_receive {
                       :agent_worker_update,
                       "issue-claude-runner",
                       %{event: :turn_started, timestamp: %DateTime{}, session_id: session_id}
                     },
                     1_000

      assert_receive {
                       :agent_worker_update,
                       "issue-claude-runner",
                       %{event: :turn_completed, timestamp: %DateTime{}, session_id: ^session_id}
                     },
                     1_000

      assert_receive {
                       :agent_worker_update,
                       "issue-claude-runner",
                       %{event: :turn_started, timestamp: %DateTime{}, session_id: ^session_id}
                     },
                     1_000

      assert_receive {
                       :agent_worker_update,
                       "issue-claude-runner",
                       %{event: :turn_completed, timestamp: %DateTime{}, session_id: ^session_id}
                     },
                     1_000

      trace = File.read!(trace_file)
      assert trace =~ "\"content\":\"You are an agent for this repository."
      assert trace =~ "\"content\":\"Continuation guidance:\\n\\n- The previous agent turn completed normally, but the issue is still in this stage."
      assert trace =~ "continuation turn #2 of 3"
    after
      Process.delete(:claude_agent_turn_fetch_count)
      File.rm_rf(test_root)
    end
  end

  describe "dashboard messages and the transcript" do
    setup do
      SymphonyElixir.AgentInbox.reset()
      SymphonyElixir.Transcript.reset()

      on_exit(fn ->
        SymphonyElixir.AgentInbox.reset()
        SymphonyElixir.Transcript.reset()
      end)

      :ok
    end

    test "queued messages are prepended to the next turn prompt" do
      %{issue: issue, trace_file: trace_file} = runner_setup!("success", 3)
      {:ok, message} = SymphonyElixir.AgentInbox.send_message(issue.identifier, "Please keep the API stable", "Mia")

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: fn _ -> {:ok, [%{issue | state: "Done"}]} end)

      [prompt] = trace_prompts(trace_file)
      assert prompt =~ "Message from Mia via the Symphony dashboard"
      assert prompt =~ "Please keep the API stable"
      assert prompt =~ "End of dashboard messages ========\n\nYou are an agent for this repository."

      assert %{status: "delivered", delivery: "next_turn"} = SymphonyElixir.AgentInbox.get(issue.identifier, message.id)

      assert [%{kind: "user", status: "delivered"}, %{kind: "turn", turn: 1, backend: "claude"}, %{kind: "agent", text: "Runner turn 1"}] =
               SymphonyElixir.Transcript.entries(issue.identifier)
    end

    test "a message sent during the last turn gets one more turn to answer it" do
      %{issue: issue, trace_file: trace_file} = runner_setup!("success", 1)

      fetcher = fn _ids ->
        count = Process.get(:inbox_fetches, 0) + 1
        Process.put(:inbox_fetches, count)
        if count == 1, do: {:ok, _} = SymphonyElixir.AgentInbox.send_message(issue.identifier, "Did you run the linter?", "Ada")
        {:ok, [issue]}
      end

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: fetcher)

      assert [first, second] = trace_prompts(trace_file)
      refute first =~ "Did you run the linter?"
      assert second =~ "Message from Ada via the Symphony dashboard"
      assert second =~ "continuation turn #2 of 2"
      assert Process.get(:inbox_fetches) == 2
    after
      Process.delete(:inbox_fetches)
    end

    test "Claude tool calls, results and thinking become structured transcript entries" do
      %{issue: issue} = runner_setup!("tools", 1)
      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: fn _ -> {:ok, [%{issue | state: "Done"}]} end)

      assert [
               %{kind: "turn"},
               %{kind: "thinking", text: "Check the tests first"},
               %{kind: "command", command: "mix test", exit_code: 1, status: "failed", body: "1 failure", backend: "claude"},
               %{kind: "edit", files: [%{path: "lib/a.ex", additions: 2, deletions: 1}], status: "completed"},
               %{kind: "agent", text: "Fixed the failing test."}
             ] = SymphonyElixir.Transcript.entries(issue.identifier)
    end
  end

  defp runner_setup!(scenario, max_turns) do
    test_root = temp_root!("inbox")
    trace_env = "SYMP_TEST_CLAUDE_TRACE_#{System.unique_integer([:positive])}"
    scenario_env = "SYMP_TEST_CLAUDE_SCENARIO_#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(test_root) end)
    on_exit(fn -> Enum.each([trace_env, scenario_env], &System.delete_env/1) end)

    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "claude-runner.trace")
    launcher = write_fake_claude_launcher!(test_root, trace_env, scenario_env)
    File.mkdir_p!(workspace_root)
    System.put_env(trace_env, trace_file)
    System.put_env(scenario_env, scenario)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_backend: "claude",
      workspace_root: workspace_root,
      hook_after_create: "printf '# test\\n' > README.md",
      claude_command: launcher,
      max_turns: max_turns
    )

    identifier = "MT-INBOX-#{System.unique_integer([:positive])}"
    %{issue: issue_fixture("issue-" <> identifier, identifier, "Answer messages"), trace_file: trace_file}
  end

  defp trace_prompts(trace_file) do
    for "JSON:" <> json <- String.split(File.read!(trace_file), "\n", trim: true) do
      json |> Jason.decode!() |> get_in(["message", "content"])
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
          tools)
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Check the tests first"},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"mix test"}},{"type":"tool_use","id":"tu2","name":"Edit","input":{"file_path":"lib/a.ex","old_string":"a","new_string":"b\\nc"}}]}}'
            printf '%s\\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","is_error":true,"content":"Exit code 1\\n1 failure"},{"type":"tool_result","tool_use_id":"tu2","content":[{"type":"text","text":"edited"}]}]}}'
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed the failing test."}]}}'
            printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"session_id\\":\\"$session_id\\",\\"uuid\\":\\"runner-result-$turn\\"}"
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
