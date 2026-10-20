defmodule SymphonyElixir.AgentInboxTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentInbox, Transcript}

  setup do
    AgentInbox.reset()
    Transcript.reset()

    on_exit(fn ->
      AgentInbox.reset()
      Transcript.reset()
    end)

    :ok
  end

  test "validates, queues, and records the message in the transcript" do
    assert {:error, :empty_message} = AgentInbox.send_message("PAY-1", "   ", "Mia")
    assert {:error, :empty_message} = AgentInbox.send_message("PAY-1", nil, "Mia")
    assert {:error, :message_too_long} = AgentInbox.send_message("PAY-1", String.duplicate("a", 8_001), "Mia")
    assert {:error, :invalid_identifier} = AgentInbox.send_message(" ", "hi", "Mia")
    assert {:error, :invalid_identifier} = AgentInbox.send_message(nil, "hi", "Mia")

    assert {:ok, message} = AgentInbox.send_message("PAY-1", "  Use the v2 API  ", "Mia")
    assert %{identifier: "PAY-1", text: "Use the v2 API", author: "Mia", status: "queued", delivery: nil, delivered_at: nil} = message
    assert "msg_" <> _ = message.id
    assert {:ok, %{author: "Someone"}} = AgentInbox.send_message("PAY-1", "second", "  ")

    assert [%{id: id}, %{text: "second"}] = AgentInbox.messages("PAY-1")
    assert id == message.id
    assert AgentInbox.get("PAY-1", id) == message
    assert AgentInbox.get("PAY-2", id) == nil
    assert AgentInbox.messages("PAY-2") == []
    assert AgentInbox.messages(nil) == []
    assert AgentInbox.queued?("PAY-1")

    assert [%{kind: "user", text: "Use the v2 API", author: "Mia", status: "queued", message_id: ^id}, _] = Transcript.entries("PAY-1")
  end

  test "the next turn takes queued messages and marks them delivered" do
    {:ok, _} = AgentInbox.send_message("PAY-3", "Also update the docs", "Mia")
    {:ok, _} = AgentInbox.send_message("PAY-3", "And the changelog", "Ada")

    assert [first, second] = taken = AgentInbox.take_queued("PAY-3")
    assert %{status: "delivered", delivery: "next_turn", delivered_at: %DateTime{}} = first
    assert second.text == "And the changelog"
    assert AgentInbox.take_queued("PAY-3") == []
    assert AgentInbox.take_queued(nil) == []
    refute AgentInbox.queued?("PAY-3")

    section = AgentInbox.prompt_section(taken)
    assert section =~ "Messages from Mia, Ada via the Symphony dashboard"
    assert section =~ "] Mia:\nAlso update the docs"
    assert section =~ "End of dashboard messages"
    assert AgentInbox.prompt_section([]) == ""
    assert AgentInbox.prompt_section([first]) =~ "Message from Mia via"

    assert Enum.all?(Transcript.entries("PAY-3"), &(&1.status == "delivered" and &1.delivery == "next_turn"))
  end

  test "a running Codex turn gets the message sent to its runner process" do
    issue = %{id: "id-PAY-4", identifier: "PAY-4"}
    {:ok, early} = AgentInbox.send_message("PAY-4", "queued before the turn", "Mia")

    AgentInbox.register_runner(issue, "codex")
    AgentInbox.codex_turn(issue, %{thread_id: "thread-1", turn_id: "turn-1"})

    # Messages queued while the turn was starting are handed over at once.
    early_id = early.id
    assert_receive {:agent_inbox, ^early_id}

    {:ok, message} = AgentInbox.send_message("PAY-4", "steer now", "Mia")
    message_id = message.id
    assert message.issue_id == "id-PAY-4"
    assert_receive {:agent_inbox, ^message_id}

    :ok = AgentInbox.mark_delivered("PAY-4", message_id, "steered")
    assert %{status: "delivered", delivery: "steered"} = AgentInbox.get("PAY-4", message_id)
    # Already delivered: a second mark changes nothing.
    :ok = AgentInbox.mark_delivered("PAY-4", message_id, "next_turn")
    assert %{delivery: "steered"} = AgentInbox.get("PAY-4", message_id)

    # Between turns nothing is sent; the message waits for the next prompt.
    AgentInbox.codex_turn(issue, nil)
    {:ok, waiting} = AgentInbox.send_message("PAY-4", "later", "Mia")
    waiting_id = waiting.id
    refute_receive {:agent_inbox, ^waiting_id}, 50

    AgentInbox.unregister_runner("PAY-4")
    {:ok, idle} = AgentInbox.send_message("PAY-4", "nobody running", "Mia")
    assert idle.issue_id == nil
    assert AgentInbox.register_runner(%{}, "codex") == :ok
    assert AgentInbox.codex_turn(%{}, nil) == :ok
    assert AgentInbox.unregister_runner(nil) == :ok
  end

  test "keeps the newest messages per issue" do
    for n <- 1..105, do: {:ok, _} = AgentInbox.send_message("PAY-5", "m#{n}", "Mia")
    messages = AgentInbox.messages("PAY-5")
    assert length(messages) == 100
    assert hd(messages).text == "m6"
  end

  test "queued messages survive a restart when a path is configured" do
    dir = Path.join(System.tmp_dir!(), "symphony-inbox-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "inbox.json")
    on_exit(fn -> File.rm_rf(dir) end)

    restart_with_path(path)
    {:ok, queued} = AgentInbox.send_message("PAY-6", "keep me", "Mia")
    {:ok, _} = AgentInbox.send_message("PAY-6", "deliver me", "Mia")
    [_, delivered] = AgentInbox.messages("PAY-6")
    :ok = AgentInbox.mark_delivered("PAY-6", delivered.id, "next_turn")
    assert File.read!(path) =~ "keep me"
    refute File.read!(path) =~ "deliver me"

    restart_with_path(path)
    assert [%{id: id, text: "keep me", status: "queued", author: "Mia"}] = AgentInbox.messages("PAY-6")
    assert id == queued.id

    File.write!(path, "not json")
    restart_with_path(path)
    assert AgentInbox.messages("PAY-6") == []
  end

  test "without the inbox running sending fails cleanly" do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, AgentInbox)
    on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, AgentInbox) end)

    assert {:error, :unavailable} = AgentInbox.send_message("PAY-7", "hi", "Mia")
    assert AgentInbox.messages("PAY-7") == []
    assert AgentInbox.take_queued("PAY-7") == []
    assert AgentInbox.mark_delivered("PAY-7", "msg_x", "steered") == :ok
    assert AgentInbox.reset() == :ok
  end

  defp restore_supervised_inbox do
    if pid = Process.whereis(AgentInbox), do: GenServer.stop(pid)
    Supervisor.restart_child(SymphonyElixir.Supervisor, AgentInbox)
  end

  # Swaps the supervised inbox for one that persists to `path`.
  defp restart_with_path(path) do
    case Process.get(:inbox_pid) do
      nil ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, AgentInbox)
        on_exit(&restore_supervised_inbox/0)

      pid ->
        GenServer.stop(pid)
    end

    {:ok, pid} = GenServer.start(AgentInbox, [path: path], name: AgentInbox)
    Process.put(:inbox_pid, pid)
  end
end
