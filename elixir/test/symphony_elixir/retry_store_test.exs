defmodule SymphonyElixir.RetryStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RetryStore

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-retry-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "retries.json")
    Application.put_env(:symphony_elixir, :retries_path, path)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :retries_path, nil)
      File.rm_rf(root)
    end)

    %{path: path}
  end

  test "saves the queue and loads it back with its metadata", %{path: path} do
    retries = %{
      "issue-1" => %{
        attempt: 3,
        due_at_unix_ms: 1_700_000_000_000,
        due_at_ms: 42,
        timer_ref: make_ref(),
        retry_token: make_ref(),
        identifier: "MT-1",
        error: "agent exited: :boom",
        labels: ["factory/implement"],
        backend: "claude"
      }
    }

    assert :ok = RetryStore.save(retries)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

    assert %{"issue-1" => %{attempt: 3, due_at_unix_ms: 1_700_000_000_000, metadata: metadata}} = RetryStore.load()
    assert metadata.identifier == "MT-1"
    assert metadata.error == "agent exited: :boom"
    assert metadata.labels == ["factory/implement"]
    assert metadata.backend == "claude"
    assert metadata.workspace_path == nil
  end

  test "skips malformed rows and defaults labels", %{path: path} do
    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "retries" => %{
          "good" => %{"attempt" => 1, "due_at_unix_ms" => 5},
          "zero" => %{"attempt" => 0, "due_at_unix_ms" => 5},
          "junk" => "nope"
        }
      })
    )

    assert %{"good" => %{attempt: 1, metadata: %{labels: []}}} = loaded = RetryStore.load()
    assert map_size(loaded) == 1
  end

  test "an unreadable or missing file loads as empty", %{path: path} do
    assert RetryStore.load() == %{}

    File.write!(path, "not json")
    assert capture_log(fn -> assert RetryStore.load() == %{} end) =~ "Retry queue unreadable"
  end

  test "a failed save is logged, not raised", %{path: path} do
    File.mkdir_p!(path)
    assert capture_log(fn -> assert :ok = RetryStore.save(%{}) end) =~ "Retry queue save failed"
  end

  test "nothing is kept without a path" do
    Application.put_env(:symphony_elixir, :retries_path, nil)
    assert :ok = RetryStore.save(%{"issue-1" => %{attempt: 1, due_at_unix_ms: 1}})
    assert RetryStore.load() == %{}
  end

  test "the default path is retries.json under the state root" do
    Application.put_env(:symphony_elixir, :retries_path, :default)
    root = Path.join(System.tmp_dir!(), "symphony-retry-root-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :state_root, root)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :state_root)
      File.rm_rf(root)
    end)

    :ok = RetryStore.save(%{"issue-1" => %{attempt: 2, due_at_unix_ms: 9}})
    assert File.exists?(Path.join(root, "retries.json"))
    assert %{"issue-1" => %{attempt: 2}} = RetryStore.load()
  end

  test "the orchestrator saves retries and restores them, claimed, after a restart", %{path: path} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    issue_id = "issue-restored"
    name = Module.concat(__MODULE__, :Orchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    ref = make_ref()

    :sys.replace_state(pid, fn state ->
      running_entry = %{
        pid: self(),
        ref: ref,
        identifier: "MT-900",
        issue: %Issue{id: issue_id, identifier: "MT-900", state: "In Progress"},
        started_at: DateTime.utc_now()
      }

      %{state | running: %{issue_id => running_entry}, claimed: MapSet.new([issue_id])}
    end)

    send(pid, {:DOWN, ref, :process, self(), :crashed})
    Process.sleep(50)
    assert %{^issue_id => %{attempt: 1, metadata: %{identifier: "MT-900"}}} = RetryStore.load()
    GenServer.stop(pid)

    log =
      capture_log(fn ->
        {:ok, restarted} = Orchestrator.start_link(name: name)
        state = :sys.get_state(restarted)
        assert %{attempt: 1, identifier: "MT-900", timer_ref: timer_ref} = state.retry_attempts[issue_id]
        assert is_reference(timer_ref)
        assert MapSet.member?(state.claimed, issue_id)

        # The retry fires; the memory tracker no longer has the issue, so it is released and forgotten.
        send(restarted, {:retry_issue, issue_id, state.retry_attempts[issue_id].retry_token})
        Process.sleep(50)
        refute MapSet.member?(:sys.get_state(restarted).claimed, issue_id)
        assert RetryStore.load() == %{}
        GenServer.stop(restarted)
      end)

    assert log =~ "Restored retry issue_id=#{issue_id} issue_identifier=MT-900"
    assert File.exists?(path)
  end
end
