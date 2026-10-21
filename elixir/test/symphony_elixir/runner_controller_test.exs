defmodule SymphonyElixirWeb.RunnerControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [assign: 3, put_req_header: 3]

  alias SymphonyElixir.{AgentInbox, RunEvents, RunnerCommands, RunToken, SessionStore, Transcript}
  alias SymphonyElixir.RunnerTestSupport, as: Support
  alias SymphonyElixirWeb.{RunnerAuth, RunnerController}

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    root = Support.temp_root!("runner-controller")
    Support.setup_runs!(root)
    AgentInbox.reset()
    Transcript.reset()
    end_ref = put_endpoint()

    on_exit(fn ->
      AgentInbox.reset()
      Transcript.reset()
      Application.put_env(:symphony_elixir, @endpoint, end_ref)
    end)

    :ok
  end

  defp put_endpoint do
    previous = Application.get_env(:symphony_elixir, @endpoint)
    endpoint = Support.start_endpoint!()
    Process.put(:runner_endpoint, endpoint)
    previous
  end

  defp run!(opts \\ []) do
    Support.record_run!("issue-1", "run-1", Keyword.merge([identifier: "MT-C-1", backend: "claude"], opts))
  end

  defp token(run_id \\ "run-1", epoch \\ 1), do: RunToken.sign(run_id, epoch)

  defp conn(method, path, token \\ token(), body \\ nil) do
    conn = build_conn() |> put_req_header("authorization", "Bearer #{token}")

    conn =
      if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    result =
      case {method, body} do
        {:get, _} -> get(conn, path)
        {:post, nil} -> post(conn, path)
        {:post, body} -> post(conn, path, Jason.encode!(body))
        {:put, body} -> put(conn, path, Jason.encode!(body))
        {:delete, _} -> delete(conn, path)
      end

    %{result | resp_body: Jason.decode!(result.resp_body)}
  end

  defp event(seq, type, data), do: %{"seq" => seq, "type" => type, "data" => RunEvents.encode(data)}

  describe "auth" do
    test "unknown runs are 404 before the token is considered" do
      assert %{status: 404, resp_body: %{"error" => "run_not_found"}} = conn(:get, "/runner/v1/runs/missing/session")
    end

    test "missing and forged tokens are 401" do
      run!()

      assert %{status: 401} = build_conn() |> get("/runner/v1/runs/run-1/session")
      assert %{status: 401} = conn(:get, "/runner/v1/runs/run-1/session", token("run-1", 1) <> "x")
      assert %{status: 401} = conn(:get, "/runner/v1/runs/run-1/session", RunToken.sign("other", 1))
    end

    test "a genuine token for an earlier epoch is fenced with 409 stale_epoch" do
      run!(epoch: 1)
      stale = token("run-1", 1)
      run!(epoch: 2)

      assert %{status: 409, resp_body: %{"error" => "stale_epoch"}} = conn(:get, "/runner/v1/runs/run-1/session", stale)
    end

    test "a valid token gets the endpoint" do
      run!()
      assert %{status: 200, resp_body: %{"record" => nil}} = conn(:get, "/runner/v1/runs/run-1/session")
    end

    test "the plug handles its own options and a missing run id" do
      assert :opts = RunnerAuth.init(:opts)

      conn = %{build_conn() | path_params: %{"run_id" => nil}} |> RunnerAuth.call([])
      assert conn.status == 404
      assert conn.halted
    end
  end

  describe "events" do
    test "each event type reaches the same place RunHost.Local reaches" do
      run!()
      run_id = "run-1"

      batch = [
        event(1, "runtime_info", %{worker_host: "build-1", workspace_path: "/ws/MT-C-1"}),
        event(2, "agent_update", %{
          issue_id: "issue-1",
          identifier: "MT-C-1",
          backend: "codex",
          message: agent_message("codex message")
        }),
        event(3, "transcript_note", %{identifier: "MT-C-1", text: "A note"}),
        event(4, "turn_started", %{identifier: "MT-C-1", info: %{turn: 1, backend: "codex"}}),
        event(5, "heartbeat", %{}),
        event(6, "agent_update", %{
          issue_id: "issue-1",
          identifier: "MT-C-1",
          backend: "claude",
          message: agent_message("claude message")
        })
      ]

      assert %{status: 200, resp_body: %{"applied_through" => 6}} =
               conn(:post, "/runner/v1/runs/#{run_id}/events", token(), %{"events" => batch})

      assert_receive {:orchestrator_message, {:worker_runtime_info, "issue-1", %{worker_host: "build-1", workspace_path: "/ws/MT-C-1"}}}
      assert_receive {:orchestrator_message, {:codex_worker_update, "issue-1", %{event: :agent_message}}}
      assert_receive {:orchestrator_message, {:agent_worker_update, "issue-1", %{event: :agent_message}}}

      assert [
               %{kind: "agent", backend: "codex", text: "codex message"},
               %{kind: "symphony", text: "A note"},
               %{kind: "turn", turn: 1, backend: "codex"},
               %{kind: "agent", backend: "claude", text: "claude message"}
             ] = Transcript.entries("MT-C-1")

      # Replaying the same batch applies nothing twice.
      assert %{status: 200, resp_body: %{"applied_through" => 6}} =
               conn(:post, "/runner/v1/runs/#{run_id}/events", token(), %{"events" => batch})

      assert length(Transcript.entries("MT-C-1")) == 4
      refute_received {:orchestrator_message, _}

      # An unknown type is ignored but its seq still counts.
      assert %{status: 200, resp_body: %{"applied_through" => 7}} =
               conn(:post, "/runner/v1/runs/#{run_id}/events", token(), %{"events" => [event(7, "mystery", %{})]})
    end

    test "finished is forwarded and ends the run for every endpoint" do
      run!()

      assert %{status: 200, resp_body: %{"applied_through" => 1}} =
               conn(:post, "/runner/v1/runs/run-1/events", token(), %{
                 "events" => [event(1, "finished", %{reason: "normal"})]
               })

      assert_receive {:orchestrator_message, {:run_finished, "issue-1", "run-1", "normal"}}

      assert %{status: 409, resp_body: %{"error" => "finished"}} =
               conn(:get, "/runner/v1/runs/run-1/session")

      assert %{status: 409, resp_body: %{"error" => "finished"}} =
               conn(:post, "/runner/v1/runs/run-1/events", token(), %{"events" => [event(2, "heartbeat", %{})]})
    end

    test "malformed batches and payloads are 400" do
      run!()

      assert %{status: 400, resp_body: %{"error" => "invalid_events"}} =
               conn(:post, "/runner/v1/runs/run-1/events", token(), %{"nope" => []})

      assert %{status: 400} =
               conn(:post, "/runner/v1/runs/run-1/events", token(), %{"events" => [%{"seq" => 1, "type" => "heartbeat", "data" => "bad!"}]})

      assert %{status: 400} =
               conn(:post, "/runner/v1/runs/run-1/events", token(), %{"events" => [%{"seq" => "x", "type" => "heartbeat"}]})

      # A non-map payload is tolerated: data_value returns nil.
      assert %{status: 200, resp_body: %{"applied_through" => 1}} =
               conn(:post, "/runner/v1/runs/run-1/events", token(), %{
                 "events" => [event(1, "transcript_note", "not a map")]
               })
    end

    test "a batch that arrives after the run finished is 409" do
      run!()

      assert {:ok, 1} =
               RunnerCommands.apply_events("run-1", [%{seq: 1, type: "finished", data: %{reason: "normal"}}], fn _ -> :ok end)

      conn =
        build_conn()
        |> assign(:run_id, "run-1")
        |> assign(:identifier, "MT-C-1")
        |> assign(:issue_id, "issue-1")
        |> assign(:backend, "claude")

      result = RunnerController.events(conn, %{"events" => [event(2, "heartbeat", %{})]})
      assert result.status == 409
      assert Jason.decode!(result.resp_body) == %{"error" => "finished"}
    end

    test "an unavailable command store answers 503" do
      run!()
      pid = Process.whereis(RunnerCommands)
      Process.unregister(RunnerCommands)

      try do
        assert %{status: 503, resp_body: %{"error" => "unavailable"}} =
                 conn(:post, "/runner/v1/runs/run-1/events", token(), %{
                   "events" => [event(1, "heartbeat", %{})]
                 })
      after
        Process.register(pid, RunnerCommands)
      end
    end
  end

  describe "session" do
    test "get, put and delete round-trip through SessionStore" do
      run!()

      assert %{status: 200, resp_body: %{"ok" => true}} =
               conn(:put, "/runner/v1/runs/run-1/session", token(), %{"record" => %{"backend" => "claude", "session_id" => "s-1"}})

      assert %{status: 200, resp_body: %{"record" => record}} = conn(:get, "/runner/v1/runs/run-1/session")
      assert record["backend"] == "claude"
      assert record["session_id"] == "s-1"

      assert %{status: 200, resp_body: %{"ok" => true}} = conn(:delete, "/runner/v1/runs/run-1/session")
      assert %{status: 200, resp_body: %{"record" => nil}} = conn(:get, "/runner/v1/runs/run-1/session")
      assert SessionStore.get("issue-1") == nil

      assert %{status: 400} = conn(:put, "/runner/v1/runs/run-1/session", token(), %{"record" => "nope"})
    end
  end

  describe "inbox" do
    test "queued messages round-trip and are marked delivered" do
      run!()
      assert {:ok, message} = AgentInbox.send_message("MT-C-1", "Please add a test", "Mia")

      assert %{status: 200, resp_body: %{"queued" => true}} = conn(:get, "/runner/v1/runs/run-1/inbox/queued")

      assert %{status: 200, resp_body: %{"message" => encoded}} = conn(:get, "/runner/v1/runs/run-1/inbox/#{message.id}")
      assert {:ok, %{id: id, text: "Please add a test", author: "Mia"}} = RunEvents.decode(encoded)
      assert id == message.id

      assert %{status: 200, resp_body: %{"messages" => encoded}} = conn(:post, "/runner/v1/runs/run-1/inbox/take")
      assert {:ok, [%{id: ^id, status: "delivered", delivery: "next_turn"}]} = RunEvents.decode(encoded)

      assert %{status: 200, resp_body: %{"queued" => false}} = conn(:get, "/runner/v1/runs/run-1/inbox/queued")
      assert %{status: 200, resp_body: %{"message" => nil}} = conn(:get, "/runner/v1/runs/run-1/inbox/missing")

      assert %{status: 200, resp_body: %{"ok" => true}} =
               conn(:post, "/runner/v1/runs/run-1/inbox/#{id}/delivered", token(), %{"delivery" => "steered"})

      assert %{status: 400} =
               conn(:post, "/runner/v1/runs/run-1/inbox/#{id}/delivered", token(), %{"delivery" => "someday"})
    end

    test "codex_turn registers a remote runner and validates the steer target" do
      run!()

      assert %{status: 200, resp_body: %{"ok" => true}} =
               conn(:post, "/runner/v1/runs/run-1/codex_turn", token(), %{
                 "steer" => %{"thread_id" => "thread-1", "turn_id" => "turn-1"}
               })

      assert [{%{remote: true, steer: %{thread_id: "thread-1", turn_id: "turn-1"}}, _pid}] =
               AgentInbox.registry() |> Registry.lookup("MT-C-1") |> Enum.map(fn {pid, value} -> {value, pid} end)

      assert %{status: 200} =
               conn(:post, "/runner/v1/runs/run-1/codex_turn", token(), %{"steer" => nil})

      assert %{status: 400} =
               conn(:post, "/runner/v1/runs/run-1/codex_turn", token(), %{"steer" => %{"thread_id" => "t"}})

      assert %{status: 400} =
               conn(:post, "/runner/v1/runs/run-1/codex_turn", token(), %{"steer" => "nope"})
    end
  end

  defp agent_message(text) do
    %{
      event: :agent_message,
      payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => text}}}
    }
  end

  describe "commands" do
    test "a message for a remote runner is delivered by the long poll" do
      run!()

      assert %{status: 200, resp_body: %{"ok" => true}} =
               conn(:post, "/runner/v1/runs/run-1/codex_turn", token(), %{
                 "steer" => %{"thread_id" => "thread-1", "turn_id" => "turn-1"}
               })

      assert {:ok, message} = AgentInbox.send_message("MT-C-1", "Steer this", "Ada")

      assert %{status: 200, resp_body: %{"commands" => [command]}} =
               conn(:get, "/runner/v1/runs/run-1/commands?after=0&wait_ms=100")

      assert %{"seq" => 1, "type" => "agent_inbox", "message_id" => id} = command
      assert id == message.id
      assert %{"commands" => []} = conn(:get, "/runner/v1/runs/run-1/commands?after=1&wait_ms=0").resp_body
    end

    test "a waiting long poll is released by a command" do
      run!()
      assert %{status: 200} = conn(:post, "/runner/v1/runs/run-1/codex_turn", token(), %{"steer" => nil})
      parent = self()

      task =
        Task.async(fn ->
          send(parent, :polling)
          conn(:get, "/runner/v1/runs/run-1/commands?after=%220%22&wait_ms=2000").resp_body
        end)

      assert_receive :polling
      Process.sleep(100)
      assert {:ok, message} = AgentInbox.send_message("MT-C-1", "Steer now", "Ada")
      assert %{"commands" => [%{"message_id" => id}]} = Task.await(task)
      assert id == message.id
    end

    test "defaults and out-of-range waits are tolerated" do
      run!()
      assert %{"commands" => []} = conn(:get, "/runner/v1/runs/run-1/commands?wait_ms=0").resp_body
      assert %{"commands" => []} = conn(:get, "/runner/v1/runs/run-1/commands?after=-1&wait_ms=0").resp_body
      assert RunnerCommands.fetch("MT-C-1", 0, 0) == []

      direct = build_conn() |> assign(:identifier, "MT-C-1")
      result = RunnerController.commands(direct, %{"after" => true, "wait_ms" => 0})
      assert %{"commands" => []} = Jason.decode!(result.resp_body)
    end
  end
end
