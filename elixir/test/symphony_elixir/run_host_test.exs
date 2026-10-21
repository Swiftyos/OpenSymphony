defmodule SymphonyElixir.RunHostTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentInbox
  alias SymphonyElixir.FactoryControls
  alias SymphonyElixir.RunHost
  alias SymphonyElixir.RunHost.Local
  alias SymphonyElixir.SessionStore
  alias SymphonyElixir.Transcript

  # A host that reports every call to its owner, so the test can see exactly
  # which controller interactions a run makes.
  defmodule RecordingHost do
    @behaviour SymphonyElixir.RunHost

    defstruct owner: nil

    @impl true
    def runtime_info(host, issue, worker_host, workspace),
      do: record(host, :runtime_info, %{issue: issue, worker_host: worker_host, workspace: workspace})

    @impl true
    def agent_update(host, issue, backend, message),
      do: record(host, :agent_update, %{issue: issue, backend: backend, message: message})

    @impl true
    def transcript_note(host, identifier, text),
      do: record(host, :transcript_note, %{identifier: identifier, text: text})

    @impl true
    def turn_started(host, identifier, info),
      do: record(host, :turn_started, %{identifier: identifier, info: info})

    @impl true
    def session_get(host, issue_id) do
      record(host, :session_get, %{issue_id: issue_id})
      nil
    end

    @impl true
    def session_put(host, issue_id, record) do
      record(host, :session_put, %{issue_id: issue_id, record: record})
      :ok
    end

    @impl true
    def session_delete(host, issue_id) do
      record(host, :session_delete, %{issue_id: issue_id})
      :ok
    end

    @impl true
    def inbox_register(host, issue, backend),
      do: record(host, :inbox_register, %{issue: issue, backend: backend})

    @impl true
    def inbox_unregister(host, identifier),
      do: record(host, :inbox_unregister, %{identifier: identifier})

    @impl true
    def inbox_take_queued(host, identifier) do
      record(host, :inbox_take_queued, %{identifier: identifier})
      []
    end

    @impl true
    def inbox_queued?(host, identifier) do
      record(host, :inbox_queued?, %{identifier: identifier})
      false
    end

    @impl true
    def inbox_prompt_section(host, messages) do
      record(host, :inbox_prompt_section, %{messages: messages})
      "[host dashboard messages]\n"
    end

    @impl true
    def codex_turn(host, issue, steer),
      do: record(host, :codex_turn, %{issue: issue, steer: steer})

    @impl true
    def inbox_get(host, identifier, id) do
      record(host, :inbox_get, %{identifier: identifier, id: id})
      nil
    end

    @impl true
    def inbox_steer_text(host, message) do
      record(host, :inbox_steer_text, %{message: message})
      "steer text"
    end

    @impl true
    def inbox_mark_delivered(host, identifier, id, delivery),
      do: record(host, :inbox_mark_delivered, %{identifier: identifier, id: id, delivery: delivery})

    defp record(host, name, payload) do
      send(host.owner, {:run_host, name, payload})
      :ok
    end
  end

  setup do
    AgentInbox.reset()
    Transcript.reset()
    FactoryControls.reset()

    on_exit(fn ->
      AgentInbox.reset()
      Transcript.reset()
      FactoryControls.reset()
    end)

    :ok
  end

  describe "a run through an injected host" do
    test "every controller interaction of the run arrives at the host, not the orchestrator" do
      test_root = temp_root!("run")
      {launcher, trace_file} = write_fake_claude_launcher!(test_root)
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        workspace_root: workspace_root,
        hook_after_create: "printf '# test\\n' > README.md",
        claude_command: launcher,
        max_turns: 1
      )

      issue = issue_fixture("issue-host", "MT-HOST-1")
      host = %RecordingHost{owner: self()}

      assert :ok =
               AgentRunner.run(issue, self(),
                 run_host: host,
                 issue_state_fetcher: fn _ -> {:ok, [issue]} end
               )

      assert_receive {:run_host, :runtime_info, %{issue: %Issue{id: "issue-host"}, worker_host: nil, workspace: workspace}},
                     1_000

      assert workspace =~ "MT-HOST-1"
      assert_receive {:run_host, :inbox_register, %{backend: "claude"}}, 1_000
      assert_receive {:run_host, :turn_started, %{identifier: "MT-HOST-1", info: %{turn: 1, backend: "claude"}}}, 1_000
      assert_receive {:run_host, :inbox_take_queued, %{identifier: "MT-HOST-1"}}, 1_000
      assert_receive {:run_host, :inbox_prompt_section, %{messages: []}}, 1_000

      assert_receive {:run_host, :session_put, %{issue_id: "issue-host", record: %{"backend" => "claude"} = record}},
                     1_000

      assert is_binary(record["session_id"])

      assert_receive {:run_host, :agent_update, %{backend: "claude", message: %{event: :turn_started}}}, 1_000
      assert_receive {:run_host, :agent_update, %{backend: "claude", message: %{event: :turn_completed}}}, 1_000

      # At max_turns the run asks the host whether a dashboard message needs a bonus turn.
      assert_receive {:run_host, :inbox_queued?, %{identifier: "MT-HOST-1"}}, 1_000
      assert_receive {:run_host, :session_delete, %{issue_id: "issue-host"}}, 1_000
      assert_receive {:run_host, :inbox_unregister, %{identifier: "MT-HOST-1"}}, 1_000

      # The host's prompt section is what reaches the agent.
      [prompt] = trace_prompts(trace_file)
      assert prompt =~ "[host dashboard messages]"

      # Nothing leaked past the host to the orchestrator.
      refute_received {:worker_runtime_info, _, _}
      refute_received {:agent_worker_update, _, _}
      refute_received {:codex_worker_update, _, _}
    end

    test "a pick-up into a different backend ends the run before starting the old backend" do
      test_root = temp_root!("handover")
      {launcher, trace_file} = write_fake_claude_launcher!(test_root)
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        agent_backend: "claude",
        workspace_root: workspace_root,
        hook_after_create: "printf '# test\n' > README.md",
        claude_command: launcher,
        max_turns: 1
      )

      {:ok, _} = FactoryControls.put("todo", "backend", "claude")
      {:ok, _} = FactoryControls.put("implement", "backend", "codex")

      issue = %{issue_fixture("issue-handover", "MT-HOST-HANDOVER") | state: "Todo"}
      host = %RecordingHost{owner: self()}

      log =
        capture_log(fn ->
          assert :ok =
                   AgentRunner.run(issue, self(),
                     run_host: host,
                     issue_state_fetcher: fn _ -> {:ok, [issue]} end
                   )
        end)

      assert log =~ "handed over"
      assert_receive {:run_host, :runtime_info, %{issue: %Issue{id: "issue-handover"}}}, 1_000
      refute_received {:run_host, :inbox_register, _}
      refute_received {:run_host, :turn_started, _}
      refute File.exists?(trace_file)
    end
  end

  describe "RunHost.Local" do
    test "runtime info goes to the recipient, and nowhere without one" do
      issue = issue_fixture("issue-local-runtime", "MT-LOCAL-1")

      assert :ok = RunHost.runtime_info(Local.new(self()), issue, "build-1", "/workspaces/MT-LOCAL-1")
      assert_receive {:worker_runtime_info, "issue-local-runtime", %{worker_host: "build-1", workspace_path: "/workspaces/MT-LOCAL-1"}}

      assert :ok = RunHost.runtime_info(Local.new(), issue, nil, "/workspaces/MT-LOCAL-1")
      assert :ok = RunHost.runtime_info(Local.new(self()), issue, nil, nil)
      refute_received {:worker_runtime_info, _, _}
    end

    test "agent updates record a transcript entry and send today's worker update message" do
      codex_issue = issue_fixture("issue-local-codex", "MT-LOCAL-2")
      claude_issue = issue_fixture("issue-local-claude", "MT-LOCAL-3")
      host = Local.new(self())
      message = agent_message("Ran echo hi")

      assert :ok = RunHost.agent_update(host, codex_issue, "codex", message)
      assert_receive {:codex_worker_update, "issue-local-codex", ^message}
      assert [%{kind: "agent", text: "Ran echo hi", backend: "codex"}] = Transcript.entries("MT-LOCAL-2")

      assert :ok = RunHost.agent_update(host, claude_issue, "claude", message)
      assert_receive {:agent_worker_update, "issue-local-claude", ^message}
      assert [%{kind: "agent", text: "Ran echo hi", backend: "claude"}] = Transcript.entries("MT-LOCAL-3")

      # No recipient: the transcript entry is still recorded.
      assert :ok = RunHost.agent_update(Local.new(), issue_fixture("issue-local-quiet", "MT-LOCAL-4"), "codex", message)
      assert [%{kind: "agent", text: "Ran echo hi"}] = Transcript.entries("MT-LOCAL-4")
      refute_received {:codex_worker_update, "issue-local-quiet", _}
    end

    test "transcript notes and turn markers go to the transcript" do
      host = Local.new()

      assert :ok = RunHost.transcript_note(host, "MT-LOCAL-5", "Agent Factory moved the issue to Done.")
      assert :ok = RunHost.turn_started(host, "MT-LOCAL-5", %{turn: 2, stage: "implement", backend: "codex"})

      assert [
               %{kind: "symphony", text: "Agent Factory moved the issue to Done."},
               %{kind: "turn", turn: 2, stage: "implement", backend: "codex"}
             ] = Transcript.entries("MT-LOCAL-5")
    end

    test "sessions go to the session store" do
      host = Local.new()

      assert :ok = RunHost.session_put(host, "issue-local-session", %{"backend" => "codex", "thread_id" => "thread-1"})
      assert %{"backend" => "codex", "thread_id" => "thread-1"} = RunHost.session_get(host, "issue-local-session")
      assert :ok = RunHost.session_delete(host, "issue-local-session")
      assert RunHost.session_get(host, "issue-local-session") == nil
      assert :ok = RunHost.session_delete(host, "issue-local-session")
      assert SessionStore.get("issue-local-session") == nil
    end

    test "inbox registration, queued messages, prompts and steering go to AgentInbox" do
      host = Local.new()
      issue = issue_fixture("issue-local-inbox", "MT-LOCAL-6")

      assert :ok = RunHost.inbox_register(host, issue, "codex")
      assert [{%{backend: "codex"}, _pid}] = pid_values(AgentInbox.registry(), "MT-LOCAL-6")

      assert {:ok, message} = AgentInbox.send_message("MT-LOCAL-6", "Please add a test", "Mia")
      assert RunHost.inbox_queued?(host, "MT-LOCAL-6")
      assert [%{id: id}] = RunHost.inbox_take_queued(host, "MT-LOCAL-6")
      assert id == message.id
      assert %{status: "delivered", delivery: "next_turn"} = RunHost.inbox_get(host, "MT-LOCAL-6", message.id)
      assert RunHost.inbox_prompt_section(host, []) == ""
      assert RunHost.inbox_steer_text(host, message) =~ "Message from Mia via the Symphony dashboard"

      assert :ok = RunHost.inbox_mark_delivered(host, "MT-LOCAL-6", message.id, "steered")
      assert %{status: "delivered", delivery: "next_turn"} = AgentInbox.get("MT-LOCAL-6", message.id)
      assert RunHost.inbox_get(host, "MT-LOCAL-6", "missing") == nil

      assert :ok = RunHost.inbox_unregister(host, "MT-LOCAL-6")
      assert AgentInbox.registry() |> Registry.lookup("MT-LOCAL-6") == []
    end

    test "codex turns register the steering target and hand queued messages to the runner process" do
      host = Local.new()
      issue = issue_fixture("issue-local-steer", "MT-LOCAL-7")

      assert :ok = RunHost.inbox_register(host, issue, "codex")
      assert :ok = RunHost.codex_turn(host, issue, %{thread_id: "thread-1", turn_id: "turn-1"})
      assert [{%{steer: %{thread_id: "thread-1", turn_id: "turn-1"}}, _pid}] = pid_values(AgentInbox.registry(), "MT-LOCAL-7")

      assert {:ok, message} = AgentInbox.send_message("MT-LOCAL-7", "Steer this turn", "Ada")
      assert_receive {:agent_inbox, message_id}
      assert message_id == message.id

      # Without an earlier registration, codex_turn registers the caller itself.
      unregistered = issue_fixture("issue-local-steer-2", "MT-LOCAL-8")

      assert :ok = RunHost.codex_turn(host, unregistered, %{thread_id: "thread-2", turn_id: "turn-2"})
      assert [{%{backend: "codex", steer: %{thread_id: "thread-2"}}, _pid}] = pid_values(AgentInbox.registry(), "MT-LOCAL-8")

      assert :ok = RunHost.codex_turn(host, issue, nil)
      assert [{%{steer: nil}, _pid}] = pid_values(AgentInbox.registry(), "MT-LOCAL-7")
    end

    test "a host is a plain value the run host module dispatches on" do
      assert RunHost.local() == %Local{recipient: nil}
      assert RunHost.local(self()) == %Local{recipient: self()}
    end
  end

  defp pid_values(registry, identifier) do
    registry |> Registry.lookup(identifier) |> Enum.map(fn {pid, value} -> {value, pid} end)
  end

  defp agent_message(text) do
    %{
      event: :agent_message,
      payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => text}}}
    }
  end

  defp issue_fixture(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Exercise the run host",
      description: "Run host test harness",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: ["backend"]
    }
  end

  defp temp_root!(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-run-host-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp trace_prompts(trace_file) do
    for "JSON:" <> json <- String.split(File.read!(trace_file), "\n", trim: true) do
      json |> Jason.decode!() |> get_in(["message", "content"])
    end
  end

  defp write_fake_claude_launcher!(test_root) do
    launcher = Path.join(test_root, "fake-claude-launcher.sh")
    trace_file = Path.join(test_root, "claude.trace")

    File.write!(
      launcher,
      """
      #!/bin/sh
      session_id=""
      previous_arg=""

      for arg in "$@"; do
        if [ "$previous_arg" = "--session-id" ]; then
          session_id="$arg"
        fi

        previous_arg="$arg"
      done

      printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "#{trace_file}"
        printf '%s\\n' "{\\"type\\":\\"system\\",\\"subtype\\":\\"init\\",\\"session_id\\":\\"$session_id\\"}"
        printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"session_id\\":\\"$session_id\\",\\"uuid\\":\\"run-host-result\\"}"
      done
      """
    )

    File.chmod!(launcher, 0o755)
    {launcher, trace_file}
  end
end
