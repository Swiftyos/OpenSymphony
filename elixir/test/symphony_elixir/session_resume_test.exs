defmodule SymphonyElixir.SessionResumeTest do
  use SymphonyElixir.TestSupport

  # Real git/process/HTTP integration; excluded by `make test-fast`.
  @moduletag :slow

  alias SymphonyElixir.ClaudeCode.AppServer, as: ClaudeAppServer
  alias SymphonyElixir.Codex.AppServer, as: CodexAppServer
  alias SymphonyElixir.SessionStore

  defp temp_root!(suffix) do
    root = Path.join(System.tmp_dir!(), "symphony-session-resume-#{suffix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  describe "SessionStore" do
    test "records survive a restart of the store and are removed on delete" do
      path = Path.join(temp_root!("store"), "sessions.json")
      name = :"session_store_#{System.unique_integer([:positive])}"

      {:ok, first} = SessionStore.start_link(path: path, name: name)
      :ok = GenServer.call(first, {:put, "issue-1", %{backend: "codex", stage: "implement", thread_id: "thread-1"}})
      GenServer.stop(first)

      {:ok, second} = SessionStore.start_link(path: path, name: name)
      assert %{"backend" => "codex", "stage" => "implement", "thread_id" => "thread-1"} = GenServer.call(second, {:get, "issue-1"})

      :ok = GenServer.call(second, {:delete, "issue-1"})
      assert GenServer.call(second, {:get, "issue-1"}) == nil
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      GenServer.stop(second)
    end
  end

  describe "Codex" do
    # Answers initialize, then the thread request (thread/resume first when resuming),
    # with the scripted responses in order.
    defp fake_codex!(root, responses) do
      binary = Path.join(root, "fake-codex")
      trace = Path.join(root, "codex.trace")

      cases =
        responses
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {response, n} -> "    #{n}) printf '%s\\n' '#{response}' ;;" end)

      File.write!(binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "#{trace}"
        case "$count" in
      #{cases}
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(binary, 0o755)
      {binary, trace}
    end

    defp codex_workflow!(root, binary) do
      workspace_root = Path.join(root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "codex",
        workspace_root: workspace_root,
        codex_command: "#{binary} app-server"
      )

      workspace
    end

    test "rejoins the interrupted thread with thread/resume" do
      root = temp_root!("codex-resume")

      {binary, trace} =
        fake_codex!(root, [~s({"id":1,"result":{}}), ~s({"id":4,"result":{"thread":{"id":"thread-old"},"cwd":"/w"}})])

      workspace = codex_workflow!(root, binary)

      assert {:ok, session} = CodexAppServer.start_session(workspace, resume_thread_id: "thread-old")
      assert session.thread_id == "thread-old"
      assert session.resumed
      CodexAppServer.stop_session(session)

      assert File.read!(trace) =~ ~s("method":"thread/resume")
      refute File.read!(trace) =~ ~s("method":"thread/start")
    end

    test "starts a new thread when the old one can't be resumed (for example a recreated sandbox)" do
      root = temp_root!("codex-fallback")

      {binary, trace} =
        fake_codex!(root, [
          ~s({"id":1,"result":{}}),
          ~s({"id":4,"error":{"code":-32600,"message":"no rollout found for thread"}}),
          ~s({"id":2,"result":{"thread":{"id":"thread-new"}}})
        ])

      workspace = codex_workflow!(root, binary)

      assert {:ok, session} = CodexAppServer.start_session(workspace, resume_thread_id: "thread-gone")
      assert session.thread_id == "thread-new"
      refute session.resumed
      CodexAppServer.stop_session(session)

      assert File.read!(trace) =~ ~s("method":"thread/start")
    end
  end

  describe "Claude Code" do
    defp fake_claude!(root) do
      launcher = Path.join(root, "fake-claude")
      trace = Path.join(root, "claude.trace")
      File.write!(launcher, "#!/bin/sh\nprintf 'ARGV:%s\\n' \"$*\" >> \"#{trace}\"\nsleep 5\n")
      File.chmod!(launcher, 0o755)
      workspace_root = Path.join(root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "claude",
        workspace_root: workspace_root,
        claude_command: launcher
      )

      {workspace, trace}
    end

    defp wait_for_file(path, tries \\ 250) do
      cond do
        File.exists?(path) -> File.read!(path)
        tries == 0 -> flunk("#{path} was never written")
        true -> Process.sleep(20) && wait_for_file(path, tries - 1)
      end
    end

    test "continues the interrupted session with --resume under its own id" do
      {workspace, trace} = fake_claude!(temp_root!("claude-resume"))

      assert {:ok, session} = ClaudeAppServer.start_session(workspace, resume_session_id: "11111111-2222-3333-4444-555555555555")
      assert session.session_id == "11111111-2222-3333-4444-555555555555"
      assert session.resumed
      argv = wait_for_file(trace)
      ClaudeAppServer.stop_session(session)

      assert argv =~ "--resume 11111111-2222-3333-4444-555555555555"
      refute argv =~ "--session-id"
    end

    test "a fresh run still starts a new session" do
      {workspace, trace} = fake_claude!(temp_root!("claude-fresh"))

      assert {:ok, session} = ClaudeAppServer.start_session(workspace)
      refute session.resumed
      argv = wait_for_file(trace)
      ClaudeAppServer.stop_session(session)

      assert argv =~ "--session-id #{session.session_id}"
    end
  end
end
