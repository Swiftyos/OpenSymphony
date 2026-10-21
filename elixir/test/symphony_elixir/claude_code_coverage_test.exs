defmodule SymphonyElixir.ClaudeCodeCoverageTest do
  use SymphonyElixir.TestSupport

  # Real git/process/HTTP integration; excluded by `make test-fast`.
  @moduletag :slow

  import ExUnit.CaptureLog

  alias SymphonyElixir.ClaudeCode.AppServer, as: ClaudeAppServer
  alias SymphonyElixir.ClaudeCode.Tooling

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-claude-cov-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "MT-COV")
    File.mkdir_p!(workspace)
    previous_path = System.get_env("PATH")
    previous_openrouter = System.get_env("OPENROUTER_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("OPENROUTER_API_KEY", previous_openrouter)
      File.rm_rf(root)
    end)

    %{root: root, workspace_root: workspace_root, workspace: workspace}
  end

  describe "AppServer.start_session/2 workspace validation" do
    setup %{root: root, workspace_root: workspace_root} do
      launcher = write_fake_claude!(root, "exec cat > /dev/null")
      configure_claude!(workspace_root, launcher)
      :ok
    end

    test "rejects the workspace root, outside paths, symlink escapes, and unreadable paths", ctx do
      %{root: root, workspace_root: workspace_root} = ctx

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _}} = ClaudeAppServer.start_session(workspace_root)

      outside = Path.join(root, "outside")
      File.mkdir_p!(outside)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, _}} =
               ClaudeAppServer.start_session(outside)

      link = Path.join(workspace_root, "escape")
      File.ln_s!(outside, link)

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^link, _}} = ClaudeAppServer.start_session(link)

      blocker = Path.join(workspace_root, "blocker")
      File.write!(blocker, "file")
      nested = Path.join(blocker, "child")

      assert {:error, {:invalid_workspace_cwd, :path_unreadable, ^nested, :enotdir}} =
               ClaudeAppServer.start_session(nested)
    end

    test "rejects blank and multi-line remote workspaces" do
      assert {:error, {:invalid_workspace_cwd, :empty_remote_workspace, "worker"}} =
               ClaudeAppServer.start_session("   ", worker_host: "worker")

      assert {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, "worker", "a\nb"}} =
               ClaudeAppServer.start_session("a\nb", worker_host: "worker")
    end
  end

  test "run/3 completes a turn with default options", %{root: root, workspace_root: workspace_root, workspace: workspace} do
    launcher =
      write_fake_claude!(root, """
      while IFS= read -r line; do
        printf '%s\\n' '{"type":"result","subtype":"success","message":{"id":"msg-1"}}'
      done
      """)

    configure_claude!(workspace_root, launcher)

    assert {:ok, %{turn_id: "msg-1", result: %{"subtype" => "success"}, session_id: session_id}} =
             ClaudeAppServer.run(workspace, "hello", nil)

    assert is_binary(session_id)
  end

  test "run_turn/4 handles split, noisy, and unusual stream lines", ctx do
    %{root: root, workspace_root: workspace_root, workspace: workspace} = ctx
    launcher = write_fake_claude!(root, "exec cat > /dev/null")
    configure_claude!(workspace_root, launcher)

    assert {:ok, session} = ClaudeAppServer.start_session(workspace)
    port = session.port
    parent = self()
    on_message = &send(parent, {:claude_message, &1})

    try do
      send(self(), {port, {:data, {:noeol, ~s({"type":"system","sub)}}})
      send(self(), {port, {:data, {:eol, ~s(type":"init","session_id":"other-session"})}}})
      send(self(), {port, {:data, {:eol, "not json at all"}}})
      send(self(), {port, {:data, {:eol, "   "}}})
      send(self(), {port, {:data, {:eol, String.duplicate("x", 1_200)}}})
      send(self(), {port, {:data, {:eol, ~s({"type":"rate_limit_event"})}}})
      send(self(), {port, {:data, {:eol, ~s({"type":"assistant"})}}})
      send(self(), {port, {:data, {:eol, ~s({"type":"assistant","message":{"content":[{"type":"image","src":"x"}]}})}}})
      send(self(), {port, {:data, {:eol, ~s({"type":"result","subtype":"success"})}}})

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, %{turn_id: nil, result: %{"subtype" => "success"}}} =
                   ClaudeAppServer.run_turn(session, "first", %{identifier: "MT-COV"}, on_message: on_message)
        end)

      assert log =~ "Claude session ID mismatch expected=#{session.session_id} actual=other-session"
      assert log =~ "Claude Code stream output: not json at all"
      assert log =~ "Claude Code stream output: #{String.duplicate("x", 1_000)}..."

      assert_received {:claude_message, %{event: :turn_started, title: "agent turn"}}

      assert_received {:claude_message,
                       %{
                         event: "message.part.updated",
                         usage: nil,
                         payload: %{"payload" => %{"properties" => %{"part" => part}}}
                       }}

      assert part == %{"type" => "text", "text" => ~s({"src":"x","type":"image"}), "sessionID" => session.session_id}
      assert_received {:claude_message, %{event: :turn_completed, usage: %{}}}

      send(self(), {port, {:data, {:eol, ~s({"type":"result","subtype":"error_during_execution"})}}})

      assert {:error, {:claude_result_error, %{"subtype" => "error_during_execution"}}} =
               ClaudeAppServer.run_turn(session, "second", nil)

      send(self(), {port, {:data, {:eol, ~s({"type":"result","subtype":"success","uuid":"u-3"})}}})

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, %{turn_id: "u-3"}} =
                   ClaudeAppServer.run_turn(session, "third", nil, on_message: fn _message -> raise "boom" end)
        end)

      assert log =~ "Claude Code on_message callback failed: boom"

      send(self(), {port, {:exit_status, 7}})
      assert {:error, {:port_exit, 7}} = ClaudeAppServer.run_turn(session, "fourth", nil)
    after
      ClaudeAppServer.stop_session(session)
    end

    assert :erlang.port_info(port) == :undefined
    assert {:error, :port_closed} = ClaudeAppServer.run_turn(session, "after stop", nil, on_message: on_message)
    assert_received {:claude_message, %{event: :turn_ended_with_error, reason: :port_closed}}
  end

  test "remote sessions stream rich assistant parts and surface error results over ssh", ctx do
    %{root: root, workspace_root: workspace_root} = ctx
    trace = Path.join(root, "ssh.trace")
    bin = Path.join(root, "ssh-bin")
    File.mkdir_p!(bin)

    assistant =
      ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hi"},) <>
        ~s({"type":"thinking","text":"hmm"},{"type":"tool_use","name":"grep"}],"usage":{"input":2}}})

    File.write!(Path.join(bin, "ssh"), """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace}"
    turn=0
    while IFS= read -r line; do
      turn=$((turn + 1))
      printf '%s\\n' '{"type":"system","subtype":"init"}'
      printf '%s\\n' '#{assistant}'
      if [ "$turn" = 1 ]; then
        printf '%s\\n' '{"type":"result","subtype":"success","uuid":"r1","usage":{"input":2,"output":1}}'
      else
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":true}'
      fi
    done
    """)

    File.chmod!(Path.join(bin, "ssh"), 0o755)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))

    configure_claude!(workspace_root, "remote-claude",
      tracker_kind: "linear",
      claude_model: "opus",
      accounts_store_root: Path.join(root, "accounts")
    )

    {:ok, account} = SymphonyElixir.Accounts.create_or_update("claude", "remote", [], Config.settings!())

    assert {:ok, session} =
             ClaudeAppServer.start_session("/srv/ws/MT-1", worker_host: "worker-9", account: account, effort: "high")

    assert %{worker_host: "worker-9", account: %{id: "remote", backend: "claude"}} = session.metadata
    parent = self()
    on_message = &send(parent, {:claude_message, &1})
    issue = %Issue{id: "i-1", identifier: "MT-1", title: "Remote", state: "In Progress"}

    try do
      assert {:ok, %{turn_id: "r1"}} = ClaudeAppServer.run_turn(session, "one", issue, on_message: on_message)
      assert_received {:claude_message, %{event: :turn_started, title: "MT-1: Remote"}}
      assert_received {:claude_message, %{event: :turn_completed, usage: %{"input" => 2, "output" => 1}}}

      parts =
        for {:claude_message, %{event: "message.part.updated", payload: payload}} <- drain_messages() do
          get_in(payload, ["payload", "properties", "part"])
        end

      assert [
               %{"type" => "text", "text" => "hi", "tokens" => %{"input" => 2}},
               %{"type" => "reasoning", "text" => "hmm"},
               %{"type" => "tool", "tool" => "grep", "state" => %{"status" => "running"}}
             ] = parts

      assert {:error, {:claude_result_error, %{"is_error" => true}}} = ClaudeAppServer.run_turn(session, "two", issue)
    after
      ClaudeAppServer.stop_session(session)
    end

    argv = File.read!(trace)
    assert argv =~ "-T worker-9 bash -lc"
    assert argv =~ "cd '"
    assert argv =~ "/srv/ws/MT-1"
    assert argv =~ "export SYMPHONY_LINEAR_API_KEY="
    assert argv =~ "exec remote-claude -p"
    assert argv =~ "--model "
    assert argv =~ "--effort "
  end

  test "run_turn/4 stops the session when no output arrives before the read timeout", ctx do
    %{root: root, workspace_root: workspace_root, workspace: workspace} = ctx
    launcher = write_fake_claude!(root, "exec cat > /dev/null")
    configure_claude!(workspace_root, launcher, claude_read_timeout_ms: 100)

    assert {:ok, session} = ClaudeAppServer.start_session(workspace)
    assert {:error, :turn_start_timeout} = ClaudeAppServer.run_turn(session, "wait", nil)
    assert :erlang.port_info(session.port) == :undefined
    assert :ok = ClaudeAppServer.stop_session(session)
  end

  test "run_turn/4 keeps polling while active and stops on a stall", ctx do
    %{root: root, workspace_root: workspace_root, workspace: workspace} = ctx
    launcher = write_fake_claude!(root, "exec cat > /dev/null")
    configure_claude!(workspace_root, launcher, claude_stall_timeout_ms: 400)

    assert {:ok, session} = ClaudeAppServer.start_session(workspace)
    send(self(), {session.port, {:data, {:eol, ~s({"type":"system","subtype":"init"})}}})

    started = System.monotonic_time(:millisecond)
    assert {:error, :stall_timeout} = ClaudeAppServer.run_turn(session, "stall", nil)
    assert System.monotonic_time(:millisecond) - started >= 400
    assert :erlang.port_info(session.port) == :undefined
  end

  test "start_session launches through the docker sandbox without a host cd", ctx do
    %{root: root, workspace_root: workspace_root, workspace: workspace} = ctx

    launcher =
      write_fake_claude!(root, """
      printf 'PWD:%s\\n' "$(pwd)" >> "#{Path.join(root, "claude.trace")}"
      while IFS= read -r line; do
        printf '%s\\n' '{"type":"result","subtype":"success","uuid":"sandboxed"}'
      done
      """)

    fake_docker = Path.join(root, "fake-docker")

    File.write!(fake_docker, """
    #!/bin/sh
    printf '%s\\n' "$*" >> "#{Path.join(root, "docker.trace")}"
    case "$1" in
      inspect) echo true; exit 0 ;;
      exec)
        for arg in "$@"; do last="$arg"; done
        cd "#{workspace}"
        exec /bin/sh -c "$last"
        ;;
    esac
    exit 1
    """)

    File.chmod!(fake_docker, 0o755)
    configure_claude!(workspace_root, launcher)
    enable_fake_sandbox!(fake_docker)

    assert {:ok, %{turn_id: "sandboxed"}} = ClaudeAppServer.run(workspace, "inside", nil)

    docker_trace = File.read!(Path.join(root, "docker.trace"))
    assert docker_trace =~ "inspect --format"
    assert docker_trace =~ ~r"exec --interactive --workdir \S*/workspaces/MT-COV "
    assert File.read!(Path.join(root, "claude.trace")) =~ "PWD:"
  end

  describe "AppServer.stop_session/1" do
    test "closes ports without an OS process" do
      {:ok, socket} = :gen_tcp.listen(0, [])
      assert is_port(socket)
      assert :ok = ClaudeAppServer.stop_session(%{port: socket})
      assert :erlang.port_info(socket) == :undefined
    end

    test "escalates to SIGKILL when the process ignores SIGTERM", ctx do
      %{root: root, workspace_root: workspace_root, workspace: workspace} = ctx
      ready = Path.join(root, "ready")
      launcher = write_fake_claude!(root, "printf ok > '#{ready}'\nexec cat > /dev/null")
      configure_claude!(workspace_root, "trap '' TERM; exec #{launcher}")

      assert {:ok, session} = ClaudeAppServer.start_session(workspace)
      wait_for_file!(ready)
      assert {:os_pid, os_pid} = :erlang.port_info(session.port, :os_pid)
      assert os_alive?(os_pid)

      assert :ok = ClaudeAppServer.stop_session(session)
      assert :erlang.port_info(session.port) == :undefined
      refute os_alive?(os_pid)
    end

    test "falls back to signalling the pid when its process group is already gone", ctx do
      %{root: root, workspace_root: workspace_root, workspace: workspace} = ctx
      orphan_pid_file = Path.join(root, "orphan.pid")

      # The launcher exits right away while a detached child (in its own session) keeps stdout open,
      # so the port stays open after the OS process and its process group are gone.
      launcher =
        write_fake_claude!(root, """
        perl -e 'use POSIX; POSIX::setsid(); open(F, ">", $ARGV[0]); print F $$; close(F); sleep 30' '#{orphan_pid_file}' &
        exit 0
        """)

      configure_claude!(workspace_root, launcher)

      assert {:ok, session} = ClaudeAppServer.start_session(workspace)
      assert {:os_pid, os_pid} = :erlang.port_info(session.port, :os_pid)
      wait_for_file!(orphan_pid_file)
      wait_until!(fn -> not os_alive?(os_pid) end)
      orphan_pid = File.read!(orphan_pid_file) |> String.trim()

      try do
        assert :erlang.port_info(session.port) != :undefined
        assert :ok = ClaudeAppServer.stop_session(session)
        assert :erlang.port_info(session.port) == :undefined
      after
        System.cmd("kill", ["-9", orphan_pid], stderr_to_stdout: true)
      end
    end

    test "still closes the port when the kill command is unavailable", ctx do
      %{root: root, workspace_root: workspace_root, workspace: workspace} = ctx
      launcher = write_fake_claude!(root, "exec cat > /dev/null")
      configure_claude!(workspace_root, launcher)

      assert {:ok, session} = ClaudeAppServer.start_session(workspace)
      assert {:os_pid, os_pid} = :erlang.port_info(session.port, :os_pid)

      empty_bin = Path.join(root, "empty-bin")
      File.mkdir_p!(empty_bin)
      previous_path = System.get_env("PATH")
      System.put_env("PATH", empty_bin)

      try do
        assert :ok = ClaudeAppServer.stop_session(session)
      after
        restore_env("PATH", previous_path)
      end

      assert :erlang.port_info(session.port) == :undefined
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end
  end

  describe "Tooling.bootstrap_workspace/3" do
    test "bootstraps remote workspaces over ssh and reports remote failures", %{root: root, workspace_root: workspace_root} do
      configure_claude!(workspace_root, "claude")
      ssh_bin = Path.join(root, "fake-ssh-bin")
      File.mkdir_p!(ssh_bin)
      ssh_log = Path.join(root, "ssh.log")
      fake_ssh = Path.join(ssh_bin, "ssh")

      File.write!(fake_ssh, """
      #!/bin/sh
      printf '%s\\n' "$*" >> "#{ssh_log}"
      if [ -n "$FAKE_SSH_FAIL" ]; then
        echo "remote bootstrap broke"
        exit 7
      fi
      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)
      System.put_env("PATH", ssh_bin <> ":" <> System.get_env("PATH", ""))
      previous_fail = System.get_env("FAKE_SSH_FAIL")
      on_exit(fn -> restore_env("FAKE_SSH_FAIL", previous_fail) end)

      System.delete_env("FAKE_SSH_FAIL")
      assert :ok = Tooling.bootstrap_workspace("/remote/ws", "worker-01", timeout_ms: 1_000)
      assert File.read!(ssh_log) =~ "worker-01"

      System.put_env("FAKE_SSH_FAIL", "1")

      assert {:error, {:claude_tooling_failed, {:remote_bootstrap_failed, "worker-01", 7, output}}} =
               Tooling.bootstrap_workspace("/remote/ws", "worker-01", timeout_ms: 1_000)

      assert output =~ "remote bootstrap broke"
    end

    test "reports remote bootstrap errors when ssh is unavailable", %{root: root, workspace_root: workspace_root} do
      configure_claude!(workspace_root, "claude", tracker_kind: "linear")
      empty_bin = Path.join(root, "no-ssh-bin")
      File.mkdir_p!(empty_bin)
      System.put_env("PATH", empty_bin)

      assert {:error, {:claude_tooling_failed, :ssh_not_found}} =
               Tooling.bootstrap_workspace("/remote/it's", "worker-01", timeout_ms: 1_000)

      configure_claude!(workspace_root, "claude")

      assert {:error, {:claude_tooling_failed, :ssh_not_found}} =
               Tooling.bootstrap_workspace("/remote/ws", "worker-01")
    end

    test "resolves gitdir files and appends to existing exclude files", ctx do
      %{root: root, workspace_root: workspace_root, workspace: workspace} = ctx
      configure_claude!(workspace_root, "claude")

      git_dir = Path.join(root, "real-git")
      File.mkdir_p!(Path.join(git_dir, "info"))
      exclude = Path.join([git_dir, "info", "exclude"])
      File.write!(exclude, "*.log")
      File.write!(Path.join(workspace, ".git"), "# worktree\ngitdir: #{git_dir}\n")

      assert :ok = Tooling.bootstrap_workspace(workspace)
      assert File.read!(exclude) == "*.log\n.symphony/\n"
      refute File.exists?(Path.join(workspace, ".symphony/claude/linear_graphql_mcp.js"))

      assert :ok = Tooling.bootstrap_workspace(workspace)
      assert File.read!(exclude) == "*.log\n.symphony/\n"
    end

    test "writes the Linear MCP server and creates missing exclude files", ctx do
      %{workspace_root: workspace_root, workspace: workspace} = ctx
      configure_claude!(workspace_root, "claude", tracker_kind: "linear")
      server = Path.join(workspace, ".symphony/claude/linear_graphql_mcp.js")

      assert :ok = Tooling.bootstrap_workspace(workspace)
      assert File.read!(server) =~ "linear_graphql"
      refute File.exists?(Path.join(workspace, ".git"))

      File.mkdir_p!(Path.join(workspace, ".git"))
      configure_claude!(workspace_root, "claude")

      assert :ok = Tooling.bootstrap_workspace(workspace)
      refute File.exists?(server)
      assert File.read!(Path.join([workspace, ".git", "info", "exclude"])) == ".symphony/\n"
    end

    test "skips git excludes when the .git file has no gitdir", %{workspace_root: workspace_root, workspace: workspace} do
      configure_claude!(workspace_root, "claude")
      File.write!(Path.join(workspace, ".git"), "not a gitdir pointer\n")

      assert :ok = Tooling.bootstrap_workspace(workspace)
      assert File.exists?(Path.join(workspace, ".symphony/claude/mcp.json"))
    end

    test "surfaces filesystem failures", %{root: root, workspace_root: workspace_root, workspace: workspace} do
      configure_claude!(workspace_root, "claude")

      blocker = Path.join(root, "blocker")
      File.write!(blocker, "file")

      assert {:error, {:claude_tooling_failed, :enotdir}} =
               Tooling.bootstrap_workspace(Path.join(blocker, "ws"))

      File.mkdir_p!(Path.join(workspace, ".symphony/claude/linear_graphql_mcp.js/inner"))

      assert {:error, {:claude_tooling_failed, reason}} = Tooling.bootstrap_workspace(workspace)
      assert reason in [:eisdir, :eperm, :eexist, :enotempty]

      File.rm_rf!(Path.join(workspace, ".symphony"))
      File.mkdir_p!(Path.join([workspace, ".git", "info", "exclude"]))

      assert {:error, {:claude_tooling_failed, %File.Error{reason: :eisdir, action: "read"}}} =
               Tooling.bootstrap_workspace(workspace)
    end
  end

  defp configure_claude!(workspace_root, command, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          agent_backend: "claude",
          tracker_kind: "memory",
          workspace_root: workspace_root,
          claude_command: command,
          claude_read_timeout_ms: 5_000,
          claude_stall_timeout_ms: 0
        ],
        overrides
      )
    )
  end

  defp enable_fake_sandbox!(fake_docker) do
    path = Workflow.workflow_file_path()
    "---\n" <> rest = File.read!(path)
    File.write!(path, "---\nsandbox:\n  kind: docker\n  command: #{fake_docker}\n  image: fake-image\n" <> rest)
    SymphonyElixir.WorkflowStore.force_reload()
    assert Config.settings!().sandbox.kind == "docker"
  end

  defp write_fake_claude!(root, body) do
    path = Path.join(root, "fake-claude-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  defp drain_messages(acc \\ []) do
    receive do
      message -> drain_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp wait_for_file!(path) do
    wait_until!(fn -> File.exists?(path) and File.read!(path) != "" end)
  end

  defp wait_until!(fun, attempts \\ 500)
  defp wait_until!(_fun, 0), do: flunk("timed out waiting for condition")

  defp wait_until!(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until!(fun, attempts - 1)
    end
  end

  defp os_alive?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", "--", Integer.to_string(os_pid)], stderr_to_stdout: true))
  end
end
