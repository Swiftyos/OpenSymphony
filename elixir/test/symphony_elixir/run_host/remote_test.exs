defmodule SymphonyElixir.RunHost.RemoteTest do
  use SymphonyElixir.TestSupport

  # Real git/process/HTTP integration; excluded by `make test-fast`.
  @moduletag :slow

  alias SymphonyElixir.{AgentInbox, RunOutbox, RunToken, Transcript}
  alias SymphonyElixir.RunHost
  alias SymphonyElixir.RunHost.Remote
  alias SymphonyElixir.RunnerCommandPoller
  alias SymphonyElixir.RunnerTestSupport, as: Support

  setup do
    root = Support.temp_root!("run-host-remote")
    Support.setup_runs!(root)
    endpoint = Support.start_endpoint!()
    AgentInbox.reset()
    Transcript.reset()

    on_exit(fn ->
      AgentInbox.reset()
      Transcript.reset()
    end)

    %{endpoint: endpoint}
  end

  defp remote!(endpoint, opts \\ []) do
    Support.record_run!("issue-1", "run-1", identifier: "MT-R-1", backend: "claude")
    name = :"remote-outbox-#{System.unique_integer([:positive])}"

    outbox =
      start_supervised!(
        {RunOutbox, name: name, run_id: "run-1", base_url: endpoint.url, token: RunToken.sign("run-1", 1), dir: Path.join(System.tmp_dir!(), "remote-outbox-#{System.unique_integer([:positive])}")}
      )

    %Remote{
      base_url: Keyword.get(opts, :base_url, endpoint.url),
      run_id: "run-1",
      token: Keyword.get(opts, :token, RunToken.sign("run-1", 1)),
      outbox: outbox
    }
  end

  test "fire-and-forget callbacks become events the controller applies", %{endpoint: endpoint} do
    host = remote!(endpoint)
    issue = Support.issue_fixture("issue-1", "MT-R-1")

    assert :ok = RunHost.runtime_info(host, issue, "build-1", "/ws/MT-R-1")
    assert :ok = RunHost.route_info(host, issue, %{backend: "claude", effort: "high"})
    assert :ok = RunHost.agent_update(host, issue, "claude", agent_message("remote message"))
    assert :ok = RunHost.transcript_note(host, "MT-R-1", "A note")
    assert :ok = RunHost.turn_started(host, "MT-R-1", %{turn: 1, backend: "claude"})
    assert :ok = RunOutbox.flush(5_000, host.outbox)

    assert_receive {:orchestrator_message, {:worker_runtime_info, "issue-1", %{worker_host: "build-1"}}}
    assert_receive {:orchestrator_message, {:worker_runtime_info, "issue-1", %{backend: "claude", effort: "high"}}}
    assert_receive {:orchestrator_message, {:agent_worker_update, "issue-1", %{event: :agent_message}}}

    assert [
             %{kind: "agent", backend: "claude", text: "remote message"},
             %{kind: "symphony", text: "A note"},
             %{kind: "turn", turn: 1, backend: "claude"}
           ] = Transcript.entries("MT-R-1")

    # Without an outbox the host still answers; there's just nowhere to send.
    quiet = %Remote{host | outbox: nil}
    assert :ok = RunHost.runtime_info(quiet, issue, nil, "/ws")
    assert :ok = RunHost.route_info(quiet, issue, %{backend: "codex"})
    assert :ok = RunHost.agent_update(quiet, issue, "claude", %{event: :x})
    assert :ok = RunHost.transcript_note(quiet, "MT-R-1", "ignored")
    assert :ok = RunHost.turn_started(quiet, "MT-R-1", %{turn: 2})
  end

  test "synchronous callbacks round-trip sessions, the inbox and Codex turns", %{endpoint: endpoint} do
    host = remote!(endpoint)
    issue = Support.issue_fixture("issue-1", "MT-R-1")

    assert RunHost.session_get(host, "issue-1") == nil
    assert :ok = RunHost.session_put(host, "issue-1", %{"backend" => "claude", "session_id" => "s-1"})
    assert %{"backend" => "claude", "session_id" => "s-1"} = RunHost.session_get(host, "issue-1")
    assert :ok = RunHost.session_delete(host, "issue-1")
    assert RunHost.session_get(host, "issue-1") == nil

    assert RunHost.inbox_take_queued(host, "MT-R-1") == []
    assert RunHost.inbox_queued?(host, "MT-R-1") == false
    assert RunHost.inbox_get(host, "MT-R-1", "missing") == nil
    assert RunHost.inbox_get(host, "MT-R-1", nil) == nil
    assert RunHost.inbox_prompt_section(host, []) == ""

    assert :ok = RunHost.inbox_register(host, issue, "codex")
    assert :ok = RunHost.inbox_register(host, issue, "codex")
    assert :ok = RunHost.codex_turn(host, issue, %{thread_id: "thread-1", turn_id: "turn-1"})
    assert :ok = RunHost.codex_turn(host, issue, %{"thread_id" => "thread-1", "turn_id" => "turn-1"})
    assert {:ok, message} = AgentInbox.send_message("MT-R-1", "Steer this", "Ada")
    assert_receive {:agent_inbox, id}, 5_000
    assert id == message.id

    assert RunHost.inbox_queued?(host, "MT-R-1") == true
    assert %{id: ^id, text: "Steer this", author: "Ada"} = RunHost.inbox_get(host, "MT-R-1", id)
    assert RunHost.inbox_steer_text(host, message) =~ "Message from Ada via the Symphony dashboard"

    assert :ok = RunHost.inbox_mark_delivered(host, "MT-R-1", id, "steered")
    assert %{status: "delivered", delivery: "steered"} = AgentInbox.get("MT-R-1", id)
    assert RunHost.inbox_mark_delivered(host, "MT-R-1", nil, "steered") == :ok

    assert :ok = RunHost.codex_turn(host, issue, nil)
    assert :ok = RunHost.inbox_unregister(host, "MT-R-1")
    assert :ok = RunHost.inbox_unregister(host, nil)

    assert_eventually(fn -> Registry.lookup(RunnerCommandPoller.registry(), "MT-R-1") == [] end)
    SymphonyElixir.RunnerCommands.reset()
  end

  test "a stale epoch and a refused token degrade reads and commands", %{endpoint: endpoint} do
    Support.record_run!("issue-1", "run-stale", epoch: 1, identifier: "MT-R-1")
    token = RunToken.sign("run-stale", 1)
    Support.record_run!("issue-1", "run-stale", epoch: 2, identifier: "MT-R-1")
    stale = %Remote{base_url: endpoint.url, run_id: "run-stale", token: token, outbox: nil}

    assert RunHost.session_get(stale, "issue-1") == nil
    assert Remote.commands(stale, 0, 10) == []

    refused = %Remote{base_url: endpoint.url, run_id: "run-stale", token: "bad-token", outbox: nil}
    assert RunHost.session_get(refused, "issue-1") == nil
    assert RunHost.inbox_queued?(refused, "MT-R-1") == false
  end

  test "the poller backs off when commands fail and ignores unknown commands", %{endpoint: endpoint} do
    host = remote!(endpoint, base_url: "http://127.0.0.1:1")
    issue = Support.issue_fixture("issue-1", "MT-R-1")

    assert :ok = RunHost.inbox_register(host, issue, "codex")
    Process.sleep(150)
    assert :ok = RunHost.inbox_unregister(host, "MT-R-1")
    SymphonyElixir.RunnerCommands.reset()

    live = %Remote{host | base_url: endpoint.url}
    assert :ok = RunHost.inbox_register(live, issue, "codex")
    assert :ok = RunHost.codex_turn(live, issue, nil)
    SymphonyElixir.RunnerCommands.push("MT-R-1", %{type: "mystery", message_id: "m"})
    assert {:ok, message} = AgentInbox.send_message("MT-R-1", "Real message", "Ada")
    assert_receive {:agent_inbox, id}, 5_000
    assert id == message.id
    assert :ok = RunHost.inbox_unregister(live, "MT-R-1")
    SymphonyElixir.RunnerCommands.reset()
  end

  test "stopping an unknown poller, and a poller without a task supervisor, is safe" do
    assert :ok = RunnerCommandPoller.stop("never-registered")
    assert :ok = RunnerCommandPoller.stop(nil)

    host = %Remote{base_url: "http://127.0.0.1:1", run_id: "run-poller", token: "t", outbox: nil}
    issue = Support.issue_fixture("issue-poller", "MT-POLLER")

    assert :ok = RunHost.inbox_register(host, issue, "codex")
    assert_eventually(fn -> Registry.lookup(RunnerCommandPoller.registry(), "MT-POLLER") != [] end)
    assert {:ok, _same} = RunnerCommandPoller.start(host, "MT-POLLER", self())

    task_supervisor = Process.whereis(SymphonyElixir.TaskSupervisor)
    Process.unregister(SymphonyElixir.TaskSupervisor)

    try do
      assert :ok = RunnerCommandPoller.stop("MT-POLLER")
    after
      Process.register(task_supervisor, SymphonyElixir.TaskSupervisor)
    end

    SymphonyElixir.RunnerCommands.reset()
  end

  test "reads degrade when the controller is unreachable", %{endpoint: endpoint} do
    host = remote!(endpoint, base_url: "http://127.0.0.1:1")
    issue = Support.issue_fixture("issue-1", "MT-R-1")

    assert RunHost.session_get(host, "issue-1") == nil
    assert :ok = RunHost.session_put(host, "issue-1", %{"backend" => "claude"})
    assert :ok = RunHost.session_delete(host, "issue-1")
    assert RunHost.inbox_take_queued(host, "MT-R-1") == []
    assert RunHost.inbox_queued?(host, "MT-R-1") == false
    assert RunHost.inbox_get(host, "MT-R-1", "missing") == nil
    assert :ok = RunHost.codex_turn(host, issue, nil)
    assert :ok = RunHost.inbox_mark_delivered(host, "MT-R-1", "m1", "next_turn")
    assert Remote.commands(host, 0, 10) == []
    assert RunHost.inbox_unregister(%Remote{host | run_id: nil}, nil) == :ok
  end

  test "an inbox registration without role for steering still hands over queued messages", %{endpoint: endpoint} do
    host = remote!(endpoint)
    issue = Support.issue_fixture("issue-1", "MT-R-1")

    assert :ok = AgentInbox.register_remote_runner("MT-R-1", "issue-1")
    assert :ok = RunHost.inbox_register(host, issue, "claude")
    # codex_turn without a steer target still marks the runner remote.
    assert :ok = RunHost.codex_turn(host, issue, nil)
    assert {:ok, _message} = AgentInbox.send_message("MT-R-1", "Hello", "Mia")
    assert_receive {:agent_inbox, _id}, 5_000
    assert :ok = RunHost.inbox_unregister(host, "MT-R-1")
    SymphonyElixir.RunnerCommands.reset()
  end

  defp agent_message(text) do
    %{
      event: :agent_message,
      payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => text}}}
    }
  end

  defp assert_eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(20)
        assert_eventually(fun, attempts - 1)
    end
  end
end
