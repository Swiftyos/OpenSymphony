defmodule SymphonyElixir.CodexSteerTest do
  use SymphonyElixir.TestSupport

  # Real git/process/HTTP integration; excluded by `make test-fast`.
  @moduletag :slow

  alias SymphonyElixir.{AgentInbox, Transcript}
  alias SymphonyElixir.Codex.AppServer, as: CodexAppServer

  setup do
    AgentInbox.reset()
    Transcript.reset()

    on_exit(fn ->
      AgentInbox.reset()
      Transcript.reset()
    end)

    :ok
  end

  test "a dashboard message steers the running Codex turn" do
    %{trace: trace, identifier: identifier, result: result, message: message} = run_steer_scenario("accept")

    assert {:ok, %{turn_id: "turn-9"}} = result
    assert %{status: "delivered", delivery: "steered", delivered_at: %DateTime{}} = AgentInbox.get(identifier, message.id)

    steer = Enum.find(trace, &(&1["method"] == "turn/steer"))
    assert steer["id"] == "symphony-steer:" <> message.id
    assert %{"threadId" => "thread-9", "expectedTurnId" => "turn-9", "input" => [%{"type" => "text", "text" => text}]} = steer["params"]
    assert text =~ "Message from Mia via the Symphony dashboard"
    assert text =~ "Please also add a test"

    assert [%{kind: "user", status: "delivered", delivery: "steered"}] = Transcript.entries(identifier)

    # The runner process is gone, and with it its registration.
    assert Registry.lookup(AgentInbox.registry(), identifier) == []
  end

  test "a rejected steer leaves the message queued for the next turn" do
    %{identifier: identifier, result: result, message: message} = run_steer_scenario("reject")

    assert {:ok, _} = result
    assert %{status: "queued"} = AgentInbox.get(identifier, message.id)
    assert [%{id: id}] = AgentInbox.take_queued(identifier)
    assert id == message.id
  end

  defp run_steer_scenario(scenario) do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-steer-#{System.unique_integer([:positive])}")
    trace_env = "SYMP_TEST_CODEX_STEER_#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(test_root) end)
    on_exit(fn -> System.delete_env(trace_env) end)

    identifier = "MT-STEER-#{System.unique_integer([:positive])}"
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, identifier)
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "codex.trace")
    File.mkdir_p!(workspace)
    System.put_env(trace_env, trace_file)
    write_fake_codex!(codex_binary, trace_env, scenario)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "codex",
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    issue = %Issue{id: "issue-steer", identifier: identifier, title: "Steer me", state: "In Progress", labels: []}
    task = Task.async(fn -> CodexAppServer.run(workspace, "Do the work", issue) end)

    wait_until(fn -> match?([{_, %{steer: %{turn_id: _}}}], Registry.lookup(AgentInbox.registry(), identifier)) end)
    {:ok, message} = AgentInbox.send_message(identifier, "Please also add a test", "Mia")
    result = Task.await(task, 10_000)

    trace =
      trace_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!(String.trim_leading(&1, "JSON:")))

    %{trace: trace, identifier: identifier, result: result, message: message}
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end

  # Lines in: initialize, initialized, thread/start, turn/start, turn/steer.
  # Responses run one line ahead, as the client only reads them after sending.
  defp write_fake_codex!(path, trace_env, scenario) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    #!/bin/sh
    trace_file="${#{trace_env}}"
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-9"}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-9"}}}'
          ;;
        4)
          printf '%s\\n' '{"method":"turn/started","params":{"threadId":"thread-9","turn":{"id":"turn-9"}}}'
          ;;
        5)
          id=$(printf '%s' "$line" | sed -n 's/.*"id":"\\(symphony-steer:[^"]*\\)".*/\\1/p')
          printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"a1","text":"Got it"}}}'
          if [ "#{scenario}" = "accept" ]; then
            printf '{"id":"%s","result":{"turnId":"turn-9"}}\\n' "$id"
          else
            printf '{"id":"%s","error":{"code":-32600,"message":"no active turn"}}\\n' "$id"
          fi
          printf '%s\\n' '{"method":"turn/completed","params":{}}'
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end
end
