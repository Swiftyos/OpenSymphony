defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  import Plug.Conn

  defmodule FakeOpenCodeState do
    use Agent

    def start_link(opts) do
      Agent.start_link(fn ->
        %{
          test_pid: Keyword.fetch!(opts, :test_pid),
          scenario: Keyword.fetch!(opts, :scenario),
          subscribers: MapSet.new(),
          permission_replies: [],
          question_rejections: [],
          aborts: []
        }
      end)
    end

    def scenario(state), do: Agent.get(state, & &1.scenario)
    def subscribe(state, pid), do: Agent.update(state, &put_in(&1.subscribers, MapSet.put(&1.subscribers, pid)))

    def broadcast(state, type, properties) do
      subscribers = Agent.get(state, &MapSet.to_list(&1.subscribers))

      Enum.each(subscribers, fn subscriber ->
        send(subscriber, {:fake_opencode_event, type, properties})
      end)

      notify(state, {:broadcast, type, properties})
    end

    def record_permission_reply(state, session_id, permission_id, body) do
      Agent.update(state, fn current ->
        update_in(current.permission_replies, &[{session_id, permission_id, body} | &1])
      end)

      notify(state, {:permission_reply, session_id, permission_id, body})
    end

    def record_question_reject(state, request_id, body) do
      Agent.update(state, fn current ->
        update_in(current.question_rejections, &[{request_id, body} | &1])
      end)

      notify(state, {:question_reject, request_id, body})
    end

    def record_abort(state, session_id, body) do
      Agent.update(state, fn current ->
        update_in(current.aborts, &[{session_id, body} | &1])
      end)

      notify(state, {:abort, session_id, body})
    end

    def wait_until(state, predicate, timeout_ms \\ 1_000) when is_function(predicate, 1) do
      deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
      do_wait_until(state, predicate, deadline_ms)
    end

    defp do_wait_until(state, predicate, deadline_ms) do
      if predicate.(Agent.get(state, & &1)) do
        :ok
      else
        if System.monotonic_time(:millisecond) >= deadline_ms do
          {:error, :timeout}
        else
          Process.sleep(10)
          do_wait_until(state, predicate, deadline_ms)
        end
      end
    end

    defp notify(state, message) do
      test_pid = Agent.get(state, & &1.test_pid)
      send(test_pid, {:fake_opencode_request, message})
      :ok
    end
  end

  defmodule FakeOpenCodePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      state = Keyword.fetch!(opts, :state)

      case {conn.method, String.split(conn.request_path, "/", trim: true)} do
        {"GET", ["global", "health"]} ->
          send(self(), :health_checked)
          json(conn, 200, %{"healthy" => true})

        {"GET", ["global", "event"]} ->
          stream_events(conn, state)

        {"POST", ["session"]} ->
          body = read_json_body!(conn)
          send(state_test_pid(state), {:fake_opencode_request, {:session_create, body}})
          json(conn, 200, %{"id" => "session-test"})

        {"POST", ["session", session_id, "message"]} ->
          body = read_json_body!(conn)
          send(state_test_pid(state), {:fake_opencode_request, {:message_post, session_id, body}})
          handle_message(conn, state, session_id)

        {"POST", ["session", session_id, "permissions", permission_id]} ->
          body = read_json_body!(conn)
          FakeOpenCodeState.record_permission_reply(state, session_id, permission_id, body)
          json(conn, 200, %{"ok" => true})

        {"POST", ["question", request_id, "reject"]} ->
          body = read_json_body!(conn)
          FakeOpenCodeState.record_question_reject(state, request_id, body)
          json(conn, 200, %{"ok" => true})

        {"POST", ["session", session_id, "abort"]} ->
          body = read_json_body!(conn)
          FakeOpenCodeState.record_abort(state, session_id, body)
          json(conn, 200, %{"ok" => true})

        _ ->
          send_resp(conn, 404, "not found")
      end
    end

    defp stream_events(conn, state) do
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      FakeOpenCodeState.subscribe(state, self())
      stream_loop(conn)
    end

    defp stream_loop(conn) do
      receive do
        {:fake_opencode_event, type, properties} ->
          case chunk(conn, sse_block(type, properties)) do
            {:ok, conn} -> stream_loop(conn)
            {:error, :closed} -> conn
          end

        :close ->
          conn
      after
        30_000 ->
          conn
      end
    end

    defp handle_message(conn, state, session_id) do
      :ok =
        FakeOpenCodeState.wait_until(
          state,
          fn current -> MapSet.size(current.subscribers) > 0 end,
          1_000
        )

      case FakeOpenCodeState.scenario(state) do
        {:success, _workspace} ->
          broadcast_success_events(state, session_id)

          json(conn, 200, %{
            "id" => "assistant-message-1",
            "info" => %{
              "id" => "assistant-message-1",
              "sessionID" => session_id,
              "tokens" => %{"input" => 12, "output" => 4, "reasoning" => 3}
            }
          })

        {:permission_within_workspace, workspace} ->
          FakeOpenCodeState.broadcast(state, "permission.asked", %{
            "id" => "perm-1",
            "sessionID" => session_id,
            "permission" => "read",
            "patterns" => [Path.join(workspace, "README.md")]
          })

          :ok =
            FakeOpenCodeState.wait_until(state, fn current ->
              Enum.any?(current.permission_replies, fn
                {^session_id, "perm-1", %{"response" => "once"}} -> true
                _ -> false
              end)
            end)

          json(conn, 200, %{
            "info" => %{
              "id" => "assistant-message-2",
              "sessionID" => session_id,
              "tokens" => %{"input" => 2, "output" => 1, "reasoning" => 0}
            }
          })

        :external_directory_permission ->
          FakeOpenCodeState.broadcast(state, "permission.asked", %{
            "id" => "perm-2",
            "sessionID" => session_id,
            "permission" => "external_directory",
            "patterns" => ["/tmp/external"]
          })

          :ok =
            FakeOpenCodeState.wait_until(state, fn current ->
              Enum.any?(current.permission_replies, fn
                {^session_id, "perm-2", %{"response" => "reject"}} -> true
                _ -> false
              end)
            end)

          json(conn, 200, %{
            "info" => %{
              "id" => "assistant-message-3",
              "sessionID" => session_id,
              "tokens" => %{"input" => 1, "output" => 1, "reasoning" => 0}
            }
          })

        :question ->
          FakeOpenCodeState.broadcast(state, "question.asked", %{
            "id" => "question-1",
            "sessionID" => session_id,
            "question" => %{"header" => "Need confirmation"}
          })

          :ok =
            FakeOpenCodeState.wait_until(state, fn current ->
              Enum.any?(current.question_rejections, fn
                {"question-1", %{}} -> true
                _ -> false
              end)
            end)

          Process.sleep(1_000)
          json(conn, 200, %{"info" => %{"id" => "assistant-message-4", "sessionID" => session_id}})

        :stall ->
          Process.sleep(1_000)
          json(conn, 200, %{"info" => %{"id" => "assistant-message-5", "sessionID" => session_id}})

        :message_post_timeout ->
          Enum.each(1..10, fn step ->
            FakeOpenCodeState.broadcast(state, "message.part.delta", %{
              "part" => %{
                "sessionID" => session_id,
                "type" => "text",
                "text" => "Still working #{step}"
              }
            })

            Process.sleep(100)
          end)

          json(conn, 200, %{"info" => %{"id" => "assistant-message-6", "sessionID" => session_id}})
      end
    end

    defp broadcast_success_events(state, session_id) do
      FakeOpenCodeState.broadcast(state, "session.status", %{
        "sessionID" => session_id,
        "status" => "running"
      })

      FakeOpenCodeState.broadcast(state, "message.part.delta", %{
        "part" => %{
          "sessionID" => session_id,
          "type" => "text",
          "text" => "Inspecting repository"
        }
      })

      FakeOpenCodeState.broadcast(state, "message.part.updated", %{
        "part" => %{
          "sessionID" => session_id,
          "type" => "step-finish",
          "tokens" => %{"input" => 7, "output" => 2, "reasoning" => 1}
        }
      })

      FakeOpenCodeState.broadcast(state, "message.updated", %{
        "info" => %{
          "sessionID" => session_id,
          "tokens" => %{"input" => 12, "output" => 4, "reasoning" => 3}
        }
      })
    end

    defp read_json_body!(conn) do
      {:ok, body, conn} = read_body(conn)
      _ = conn

      case body do
        "" -> %{}
        payload -> Jason.decode!(payload)
      end
    end

    defp json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    defp sse_block(type, properties) do
      "event: message\n" <>
        "data: " <> Jason.encode!(%{"payload" => %{"type" => type, "properties" => properties}}) <> "\n\n"
    end

    defp state_test_pid(state), do: Agent.get(state, & &1.test_pid)
  end

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = issue_fixture("issue-workspace-guard", "MT-999", "Validate workspace guard")

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = issue_fixture("issue-workspace-symlink-guard", "MT-1000", "Validate symlink workspace guard")

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               AppServer.run(symlink_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server starts OpenCode, creates a session, streams updates, and posts the turn message" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-opencode-run-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-101")
      File.mkdir_p!(workspace)

      server = start_fake_opencode_server!({:success, workspace})
      launcher = write_launcher_script!(test_root, server.base_url)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        opencode_command: launcher,
        opencode_agent: "build",
        opencode_model: "openai/gpt-5.4"
      )

      parent = self()

      assert {:ok, result} =
               AppServer.run(
                 workspace,
                 "Ship the change",
                 issue_fixture(),
                 variant: "max",
                 on_message: &send(parent, {:agent_message, &1})
               )

      assert result.session_id == "session-test"
      assert result.thread_id == "session-test"
      assert result.turn_id == "assistant-message-1"

      assert_receive {:fake_opencode_request, {:session_create, %{"title" => "MT-101"}}}, 1_000

      assert_receive {:fake_opencode_request,
                      {:message_post, "session-test",
                       %{
                         "agent" => "build",
                         "model" => %{"providerID" => "openai", "modelID" => "gpt-5.4"},
                         "variant" => "max",
                         "parts" => [%{"type" => "text", "text" => "Ship the change"}]
                       }}},
                     1_000

      assert_receive {:agent_message, %{event: :turn_started, session_id: "session-test"}}, 1_000
      assert_receive {:agent_message, %{event: "session.status", payload: %{"payload" => %{"type" => "session.status"}}}}, 1_000
      assert_receive {:agent_message, %{event: "message.part.delta"}}, 1_000
      assert_receive {:agent_message, %{event: "message.part.updated", usage: %{input: 7, output: 2, reasoning: 1, total: 10}}}, 1_000
      assert_receive {:agent_message, %{event: "message.updated", usage: %{input: 12, output: 4, reasoning: 3, total: 19}}}, 1_000
      assert_receive {:agent_message, %{event: :turn_completed, usage: %{input: 12, output: 4, reasoning: 3, total: 19}}}, 1_000
    after
      File.rm_rf(test_root)
    end
  end

  test "app server approves workspace-contained permission requests once" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-opencode-permission-allow-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-102")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "hello\n")

      server = start_fake_opencode_server!({:permission_within_workspace, workspace})
      launcher = write_launcher_script!(test_root, server.base_url)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        opencode_command: launcher
      )

      assert {:ok, _result} =
               AppServer.run(workspace, "Read the workspace", issue_fixture("issue-perm-allow", "MT-102", "Permission allow"))

      assert_receive {:fake_opencode_request, {:permission_reply, "session-test", "perm-1", %{"response" => "once"}}}, 1_000
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects external directory permission requests" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-opencode-permission-reject-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-103")
      File.mkdir_p!(workspace)

      server = start_fake_opencode_server!(:external_directory_permission)
      launcher = write_launcher_script!(test_root, server.base_url)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        opencode_command: launcher
      )

      assert {:ok, _result} =
               AppServer.run(workspace, "Reject the external path", issue_fixture("issue-perm-reject", "MT-103", "Permission reject"))

      assert_receive {:fake_opencode_request, {:permission_reply, "session-test", "perm-2", %{"response" => "reject"}}}, 1_000
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects interactive questions as input-required failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-opencode-question-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-104")
      File.mkdir_p!(workspace)

      server = start_fake_opencode_server!(:question)
      launcher = write_launcher_script!(test_root, server.base_url)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        opencode_command: launcher,
        opencode_read_timeout_ms: 2_000
      )

      assert {:error, {:turn_input_required, %{"id" => "question-1"}}} =
               AppServer.run(workspace, "Need confirmation", issue_fixture("issue-question", "MT-104", "Question"))

      assert_receive {:fake_opencode_request, {:question_reject, "question-1", %{}}}, 1_000
    after
      File.rm_rf(test_root)
    end
  end

  test "app server returns actionable timeout details when posting a turn message times out" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-opencode-message-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-105")
      File.mkdir_p!(workspace)

      server = start_fake_opencode_server!(:message_post_timeout)
      launcher = write_launcher_script!(test_root, server.base_url)
      parent = self()

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        opencode_command: launcher,
        opencode_read_timeout_ms: 500,
        opencode_stall_timeout_ms: 5_000
      )

      assert {:error,
              %{
                kind: :message_post_timeout,
                phase: :post_turn_message,
                session_id: "session-test",
                read_timeout_ms: 500,
                method: "POST",
                path: "/session/session-test/message",
                message: message,
                hint: hint
              }} =
               AppServer.run(
                 workspace,
                 "Wait too long",
                 issue_fixture("issue-message-timeout", "MT-105", "Message timeout"),
                 on_message: &send(parent, {:agent_message, &1})
               )

      assert message =~ "OpenCode did not respond to POST /session/session-test/message"
      assert hint =~ "Increase opencode.read_timeout_ms"

      assert_receive {:fake_opencode_request, {:message_post, "session-test", _body}}, 1_000
      assert_receive {:agent_message, %{event: :turn_started, session_id: "session-test"}}, 1_000
      assert_receive {:agent_message, %{event: "message.part.delta"}}, 1_000

      assert_receive {:agent_message, %{event: :turn_ended_with_error, reason: %{kind: :message_post_timeout, message: ^message}}},
                     1_000
    after
      File.rm_rf(test_root)
    end
  end

  test "app server aborts the session on stall timeout" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-opencode-stall-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-105")
      File.mkdir_p!(workspace)

      server = start_fake_opencode_server!(:stall)
      launcher = write_launcher_script!(test_root, server.base_url)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        opencode_command: launcher,
        opencode_turn_timeout_ms: 1_000,
        opencode_read_timeout_ms: 2_000,
        opencode_stall_timeout_ms: 50
      )

      assert {:error, :stall_timeout} =
               AppServer.run(workspace, "Wait too long", issue_fixture("issue-stall", "MT-105", "Stall timeout"))

      assert_receive {:fake_opencode_request, {:abort, "session-test", %{}}}, 1_000
    after
      File.rm_rf(test_root)
    end
  end

  defp issue_fixture(id \\ "issue-1", identifier \\ "MT-101", title \\ "Test issue") do
    %Issue{
      id: id,
      identifier: identifier,
      title: title,
      description: "Exercise the OpenCode app server test harness",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: ["backend"]
    }
  end

  defp start_fake_opencode_server!(scenario) do
    {:ok, state} = start_supervised({FakeOpenCodeState, test_pid: self(), scenario: scenario})
    bandit = start_supervised!({Bandit, plug: {FakeOpenCodePlug, state: state}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    %{state: state, bandit: bandit, base_url: "http://127.0.0.1:#{port}"}
  end

  defp write_launcher_script!(test_root, base_url) do
    launcher = Path.join(test_root, "fake-opencode-launcher.sh")

    File.write!(launcher, """
    #!/bin/sh
    printf 'opencode server listening on #{base_url}\\n'
    while true; do
      sleep 1
    done
    """)

    File.chmod!(launcher, 0o755)
    launcher
  end
end
