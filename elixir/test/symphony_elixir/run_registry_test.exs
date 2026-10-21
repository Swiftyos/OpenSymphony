defmodule SymphonyElixir.RunRegistryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RetryStore
  alias SymphonyElixir.RunLauncher.Local
  alias SymphonyElixir.RunRegistry

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-run-registry-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "runs.json")
    Application.put_env(:symphony_elixir, :runs_path, path)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :runs_path, nil)
      Application.put_env(:symphony_elixir, :retries_path, nil)
      File.rm_rf(root)
    end)

    %{path: path, root: root}
  end

  test "records a run and loads it back with its metadata", %{path: path} do
    assert :ok = RunRegistry.record("issue-1", entry())
    assert Bitwise.band(File.stat!(RunRegistry.doc_path(path, "issue-1")).mode, 0o777) == 0o600

    assert %{"issue-1" => loaded} = RunRegistry.load()
    assert loaded.run_id == "run-1"
    assert loaded.attempt == 2
    assert loaded.epoch == 1
    assert loaded.launcher == Local
    assert loaded.ref == entry().ref
    assert loaded.started_at_unix_ms == 1_700_000_000_000
    assert loaded.metadata.identifier == "MT-1"
    assert loaded.metadata.issue_title == "Work"
    assert loaded.metadata.labels == ["factory/implement"]
    assert loaded.metadata.backend == "claude"
    assert loaded.metadata.worker_host == "host-a"
    assert loaded.metadata.workspace_path == "/tmp/work"
  end

  test "the issue and event progress survive a reload", %{path: path} do
    issue = %Issue{
      id: "issue-1",
      identifier: "MT-1",
      title: "Work",
      state: "In Progress",
      labels: ["factory/implement"],
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    assert :ok = RunRegistry.record("issue-1", entry(%{metadata: %{identifier: "MT-1", issue: issue}, last_seq: 2, finished: "normal"}))
    assert %{"issue-1" => loaded} = RunRegistry.load()
    assert %Issue{identifier: "MT-1", created_at: ~U[2026-01-01 00:00:00Z]} = loaded.metadata.issue
    assert loaded.last_seq == 2
    assert loaded.finished == "normal"

    # Progress for this run moves forward, never backwards, and keeps the reason.
    assert :ok = RunRegistry.advance_progress("issue-1", "run-1", 1, nil)
    assert RunRegistry.load()["issue-1"].last_seq == 2
    assert :ok = RunRegistry.advance_progress("issue-1", "run-1", 9, "failed")
    assert :ok = RunRegistry.advance_progress("issue-1", "run-1", 10)
    loaded = RunRegistry.load()["issue-1"]
    assert loaded.last_seq == 10
    assert loaded.finished == "failed"

    # Another run's / invalid progress is ignored.
    assert :ok = RunRegistry.advance_progress("issue-1", "other-run", 20, "nope")
    assert RunRegistry.load()["issue-1"].last_seq == 10
    assert :ok = RunRegistry.advance_progress(nil, nil, -1, nil)
    assert :ok = RunRegistry.advance_progress("missing", "run-x", 1, nil)

    # A map with string keys still rebuilds an issue.
    assert :ok = RunRegistry.record("issue-string", entry(%{metadata: %{identifier: "MT-S", issue: %{"id" => "issue-string", "identifier" => "MT-S", "labels" => []}}}))
    assert %Issue{identifier: "MT-S"} = RunRegistry.load()["issue-string"].metadata.issue

    # A Date in the issue metadata also encodes safely.
    assert :ok =
             RunRegistry.record(
               "issue-date",
               entry(%{metadata: %{identifier: "MT-D", issue: %Issue{id: "issue-date", identifier: "MT-D", created_at: ~D[2026-01-01]}}})
             )

    assert File.exists?(RunRegistry.doc_path(path, "issue-date"))

    # Every write is in the store: a fresh load from it sees the same runs.
    cached = Map.new(RunRegistry.load(), fn {issue_id, entry} -> {issue_id, {entry.run_id, entry.last_seq, entry.finished}} end)
    :ok = RunRegistry.reload()
    assert Map.new(RunRegistry.load(), fn {issue_id, entry} -> {issue_id, {entry.run_id, entry.last_seq, entry.finished}} end) == cached
  end

  test "delete forgets the run but keeps its epoch", %{path: path} do
    assert :ok = RunRegistry.record("issue-1", entry(%{epoch: 3}))
    assert RunRegistry.next_epoch("issue-1") == 4

    assert :ok = RunRegistry.delete("issue-1")
    assert RunRegistry.load() == %{}
    assert RunRegistry.next_epoch("issue-1") == 4

    # The epoch survives a re-read of the document, as it does across a restart.
    assert %{"issue_id" => "issue-1", "epoch" => 3, "run" => nil} = disk_doc(path, "issue-1")
    :ok = RunRegistry.reload()
    assert RunRegistry.next_epoch("issue-1") == 4

    # Deleting an issue with no run (or none at all) writes nothing.
    File.rm!(RunRegistry.doc_path(path, "issue-1"))
    assert :ok = RunRegistry.delete("issue-1")
    assert :ok = RunRegistry.delete("issue-never")
    refute File.exists?(RunRegistry.doc_path(path, "issue-1"))
  end

  test "epochs increase per issue across restarts and are independent", %{path: path} do
    assert RunRegistry.next_epoch("issue-1") == 1
    assert :ok = RunRegistry.record("issue-1", entry(%{epoch: RunRegistry.next_epoch("issue-1")}))

    assert RunRegistry.next_epoch("issue-1") == 2
    assert RunRegistry.next_epoch("issue-2") == 1

    assert :ok = RunRegistry.record("issue-1", entry(%{run_id: "run-2", epoch: RunRegistry.next_epoch("issue-1"), attempt: 3}))
    assert RunRegistry.next_epoch("issue-1") == 3

    # A stale epoch never moves the counter back.
    assert :ok = RunRegistry.record("issue-1", entry(%{run_id: "run-3", epoch: 1}))
    assert RunRegistry.next_epoch("issue-1") == 3
    assert %{"epoch" => 2, "run" => %{"epoch" => 1, "run_id" => "run-3"}} = disk_doc(path, "issue-1")
  end

  test "malformed rows are skipped and launchers are parsed safely", %{path: path} do
    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "runs" => %{
          "good" => %{
            "run_id" => "run-good",
            "attempt" => 1,
            "epoch" => 1,
            "ref" => "local:boot:0.1.0",
            "started_at_unix_ms" => 5
          },
          "unknown-launcher" => %{
            "run_id" => "run-unknown",
            "attempt" => 1,
            "epoch" => 2,
            "launcher" => "No.Such.Module",
            "ref" => "local:boot:0.2.0",
            "started_at_unix_ms" => 6
          },
          "known-launcher" => %{
            "run_id" => "run-known",
            "attempt" => 0,
            "epoch" => 3,
            "launcher" => "Elixir.SymphonyElixir.RunLauncher.Local",
            "ref" => "local:boot:0.3.0",
            "started_at_unix_ms" => 7,
            "metadata" => "not a map"
          },
          "bad-attempt" => %{
            "run_id" => "run-bad",
            "attempt" => -1,
            "epoch" => 1,
            "ref" => "local:boot:0.4.0",
            "started_at_unix_ms" => 8
          },
          "no-run-id" => %{"run_id" => "", "attempt" => 1, "epoch" => 1, "ref" => "x", "started_at_unix_ms" => 8},
          "junk" => "nope"
        },
        "epochs" => %{"good" => 2, "bad" => "nope"}
      })
    )

    assert %{"good" => good, "unknown-launcher" => unknown, "known-launcher" => known} = loaded = RunRegistry.load()
    assert map_size(loaded) == 3
    assert good.launcher == nil
    assert good.metadata.labels == []
    assert unknown.launcher == "No.Such.Module"
    assert known.launcher == Local
    assert known.attempt == 0
    assert known.metadata.labels == []

    assert RunRegistry.next_epoch("good") == 3
    assert RunRegistry.next_epoch("bad") == 1
  end

  test "a legacy runs.json is migrated once into per-issue documents", %{path: path} do
    legacy_run = %{"run_id" => "run-legacy", "attempt" => 1, "epoch" => 2, "ref" => "local:boot:0.1.0", "started_at_unix_ms" => 5, "last_seq" => 4}
    newer_run = %{"run_id" => "run-newer", "attempt" => 0, "epoch" => 1, "ref" => "local:boot:0.2.0", "started_at_unix_ms" => 6}

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "runs" => %{"issue-legacy" => legacy_run, "issue-both" => legacy_run},
        "epochs" => %{"issue-legacy" => 5, "issue-epoch-only" => 7, "issue-both" => 9}
      })
    )

    # A per-issue document already there keeps its run; the epoch is the higher one.
    File.mkdir_p!(RunRegistry.dir(path))
    File.write!(RunRegistry.doc_path(path, "issue-both"), Jason.encode!(%{"issue_id" => "issue-both", "epoch" => 1, "run" => newer_run}))

    log = capture_log(fn -> assert map_size(RunRegistry.load()) == 2 end)
    assert log =~ "Run registry migrated to per-issue documents"

    loaded = RunRegistry.load()
    assert %{run_id: "run-legacy", last_seq: 4} = loaded["issue-legacy"]
    assert %{run_id: "run-newer"} = loaded["issue-both"]
    assert RunRegistry.next_epoch("issue-legacy") == 6
    assert RunRegistry.next_epoch("issue-epoch-only") == 8
    assert RunRegistry.next_epoch("issue-both") == 10
    assert {"issue-legacy", %{run_id: "run-legacy"}} = RunRegistry.find_run("run-legacy")

    # The legacy file is emptied with a marker, and not migrated again.
    assert %{"migrated_to" => "run_registry", "runs" => %{}, "epochs" => %{}} = path |> File.read!() |> Jason.decode!()
    assert %{"epoch" => 7, "run" => nil} = disk_doc(path, "issue-epoch-only")
    :ok = RunRegistry.reload()
    refute capture_log(fn -> assert map_size(RunRegistry.load()) == 2 end) =~ "migrated"
  end

  test "find_run finds a run by its id, and only the issue's current run", %{path: path} do
    assert RunRegistry.find_run("run-1") == nil
    assert RunRegistry.find_run(nil) == nil

    :ok = RunRegistry.record("issue-1", entry())
    assert {"issue-1", %{run_id: "run-1"}} = RunRegistry.find_run("run-1")

    # A new run for the issue replaces the old one in the index.
    :ok = RunRegistry.record("issue-1", entry(%{run_id: "run-2", epoch: 2}))
    assert RunRegistry.find_run("run-1") == nil
    assert {"issue-1", %{run_id: "run-2"}} = RunRegistry.find_run("run-2")

    :ok = RunRegistry.delete("issue-1")
    assert RunRegistry.find_run("run-2") == nil

    # Without the server's cache it reads the store.
    :ok = RunRegistry.record("issue-3", entry(%{run_id: "run-3"}))
    assert path |> RunRegistry.read_store() |> Map.fetch!("issue-3") |> Map.fetch!(:run) |> Map.fetch!(:run_id) == "run-3"
  end

  test "an unreadable issue document is skipped", %{path: path} do
    File.mkdir_p!(RunRegistry.dir(path))
    File.write!(Path.join(RunRegistry.dir(path), "junk.json"), "not json")
    File.write!(Path.join(RunRegistry.dir(path), "no-issue.json"), Jason.encode!(%{"epoch" => 1}))
    File.write!(RunRegistry.doc_path(path, "issue-bad-run"), Jason.encode!(%{"issue_id" => "issue-bad-run", "epoch" => "x", "run" => "nope"}))

    log = capture_log(fn -> assert RunRegistry.load() == %{} end)
    assert log =~ "Run registry document unreadable"
    assert RunRegistry.next_epoch("issue-bad-run") == 1
  end

  test "lookups stay constant-time with a thousand runs" do
    for n <- 1..1_000, do: :ok = RunRegistry.record("issue-#{n}", entry(%{run_id: "run-#{n}", metadata: %{identifier: "MT-#{n}"}}))

    {micros, found} = :timer.tc(fn -> for n <- 1..1_000, do: RunRegistry.find_run("run-#{n}") end)
    assert Enum.all?(found, &match?({_issue_id, %{}}, &1))
    # 1,000 lookups among 1,000 runs; decoding the registry per lookup took seconds.
    assert micros < 1_000_000

    {micros, _epochs} = :timer.tc(fn -> for n <- 1..1_000, do: RunRegistry.next_epoch("issue-#{n}") end)
    assert micros < 1_000_000
  end

  test "non-object runs and epochs sections load as empty", %{path: path} do
    File.write!(path, Jason.encode!(%{"version" => 1, "runs" => "nope", "epochs" => []}))

    assert RunRegistry.load() == %{}
    assert RunRegistry.next_epoch("issue-1") == 1
  end

  test "an unreadable or missing file loads as empty", %{path: path} do
    assert RunRegistry.load() == %{}
    assert RunRegistry.next_epoch("issue-1") == 1

    File.write!(path, "not json")
    :ok = RunRegistry.reload()
    assert capture_log(fn -> assert RunRegistry.load() == %{} end) =~ "Run registry unreadable"
  end

  test "a sparse entry is normalized, and a failed save is logged", %{path: path} do
    sparse = %{run_id: "run-sparse", ref: "local:boot:0.1.0", started_at_unix_ms: 1, attempt: :nope, epoch: 0, launcher: "launcher-name", metadata: nil}

    assert :ok = RunRegistry.record("issue-sparse", sparse)
    assert %{"issue-sparse" => loaded} = RunRegistry.load()
    assert loaded.attempt == 0
    assert loaded.epoch == 1
    assert loaded.launcher == "launcher-name"
    assert loaded.metadata.labels == []
    assert loaded.metadata.identifier == nil

    assert :ok = RunRegistry.record("issue-nil-launcher", Map.put(sparse, :launcher, nil))
    assert %{"issue-nil-launcher" => %{launcher: nil}} = RunRegistry.load()

    # The per-issue documents' directory is a file: the save fails.
    File.rm_rf!(RunRegistry.dir(path))
    File.write!(RunRegistry.dir(path), "")
    assert capture_log(fn -> assert :ok = RunRegistry.record("issue-failed", entry()) end) =~ "Run registry save failed"
  end

  test "an invalid stored seq and reason normalize to safe values", %{path: path} do
    File.write!(
      path,
      Jason.encode!(%{
        "runs" => %{
          "issue-1" => %{
            "run_id" => "run-1",
            "attempt" => 1,
            "epoch" => 1,
            "ref" => "local:boot:0.1.0",
            "started_at_unix_ms" => 5,
            "last_seq" => "nope",
            "finished" => 7
          }
        },
        "epochs" => %{}
      })
    )

    assert %{"issue-1" => entry} = RunRegistry.load()
    assert entry.last_seq == 0
    assert entry.finished == nil
  end

  test "nothing is kept without a path" do
    Application.put_env(:symphony_elixir, :runs_path, nil)

    assert :ok = RunRegistry.record("issue-1", entry())
    assert :ok = RunRegistry.delete("issue-1")
    assert :ok = RunRegistry.advance_progress("issue-1", "run-1", 3, "normal")
    assert RunRegistry.load() == %{}
    assert RunRegistry.next_epoch("issue-1") == 1
    assert is_binary(RunRegistry.new_run_id())
  end

  test "the default path is runs.json under the state root" do
    Application.put_env(:symphony_elixir, :runs_path, :default)
    root = Path.join(System.tmp_dir!(), "symphony-run-root-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :state_root, root)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :state_root)
      File.rm_rf(root)
    end)

    :ok = RunRegistry.record("issue-1", entry())
    assert File.exists?(RunRegistry.doc_path(Path.join(root, "runs.json"), "issue-1"))
    assert %{"issue-1" => %{run_id: "run-1"}} = RunRegistry.load()
  end

  test "the orchestrator retries a run cut off by a restart with its next attempt", %{path: path} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    issue_id = "issue-interrupted"

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: issue_id, identifier: "MT-901", title: "Interrupted", state: "In Progress"}
    ])

    :ok =
      RunRegistry.record(
        issue_id,
        entry(%{
          attempt: 2,
          epoch: 4,
          ref: "local:previousboot:0.1.0",
          metadata: %{
            identifier: "MT-901",
            issue_title: "Interrupted",
            labels: ["factory/implement"],
            backend: "claude",
            worker_host: "host-a",
            workspace_path: "/tmp/work"
          }
        })
      )

    name = Module.concat(__MODULE__, "RecoveryOrchestrator")

    log =
      capture_log(fn ->
        {:ok, pid} = Orchestrator.start_link(name: name)

        state = :sys.get_state(pid)
        assert RunRegistry.load() == %{}

        assert %{attempt: 3, identifier: "MT-901", error: "interrupted by a Symphony restart", worker_host: "host-a", workspace_path: "/tmp/work"} =
                 state.retry_attempts[issue_id]

        assert MapSet.member?(state.claimed, issue_id)
        GenServer.stop(pid)
      end)

    assert log =~ "Recovered interrupted run issue_id=#{issue_id} issue_identifier=MT-901 attempt=2"
    assert %{"run" => nil, "epoch" => 4} = disk_doc(path, issue_id)
  end

  test "an issue with a restored retry keeps it instead of scheduling another", %{root: root} do
    retries_path = Path.join(root, "retries.json")
    Application.put_env(:symphony_elixir, :retries_path, retries_path)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    issue_id = "issue-both"

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: issue_id, identifier: "MT-902", title: "Both", state: "In Progress"}
    ])

    :ok =
      RetryStore.save(%{
        issue_id => %{
          attempt: 4,
          due_at_unix_ms: System.system_time(:millisecond) + 60_000,
          identifier: "MT-902",
          error: "prior failure",
          labels: []
        }
      })

    :ok = RunRegistry.record(issue_id, entry(%{attempt: 1, epoch: 1, ref: "local:previousboot:0.1.0"}))

    name = Module.concat(__MODULE__, "BothOrchestrator")
    {:ok, pid} = Orchestrator.start_link(name: name)

    state = :sys.get_state(pid)
    assert %{attempt: 4, error: "prior failure", identifier: "MT-902"} = state.retry_attempts[issue_id]
    assert RunRegistry.load() == %{}
    assert MapSet.member?(state.claimed, issue_id)

    GenServer.stop(pid)
  end

  test "a run that leaves running on :DOWN is deleted from the registry" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    issue_id = "issue-down"

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: issue_id, identifier: "MT-903", title: "Down", state: "In Progress"}
    ])

    name = Module.concat(__MODULE__, "DownOrchestrator")
    {:ok, pid} = Orchestrator.start_link(name: name)

    {:ok, task_pid, run_ref} = Local.start(fn -> Process.sleep(:infinity) end, [])
    monitor_ref = Process.monitor(task_pid)

    :ok =
      RunRegistry.record(
        issue_id,
        entry(%{
          attempt: 1,
          epoch: 1,
          ref: run_ref,
          metadata: %{identifier: "MT-903", issue_title: "Down", worker_host: nil, workspace_path: nil}
        })
      )

    assert Map.has_key?(RunRegistry.load(), issue_id)

    running_entry = %{
      pid: task_pid,
      ref: monitor_ref,
      run_ref: run_ref,
      launcher: Local,
      identifier: "MT-903",
      retry_attempt: 1,
      issue: %Issue{id: issue_id, identifier: "MT-903", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn state ->
      %{state | running: %{issue_id => running_entry}, claimed: MapSet.new([issue_id])}
    end)

    send(pid, {:DOWN, monitor_ref, :process, task_pid, :boom})
    Process.sleep(50)

    state = :sys.get_state(pid)
    assert RunRegistry.load() == %{}
    refute Map.has_key?(state.running, issue_id)
    assert %{attempt: 2, error: "agent exited: :boom"} = state.retry_attempts[issue_id]

    Local.stop(run_ref)
    GenServer.stop(pid)
  end

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        run_id: "run-1",
        attempt: 2,
        epoch: 1,
        launcher: Local,
        ref: "local:boot:" <> pid_string(self()),
        started_at_unix_ms: 1_700_000_000_000,
        metadata: %{
          identifier: "MT-1",
          issue_title: "Work",
          labels: ["factory/implement"],
          backend: "claude",
          worker_host: "host-a",
          workspace_path: "/tmp/work"
        }
      },
      overrides
    )
  end

  defp disk_doc(path, issue_id), do: path |> RunRegistry.doc_path(issue_id) |> File.read!() |> Jason.decode!()

  defp pid_string(pid) do
    pid
    |> :erlang.pid_to_list()
    |> List.to_string()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
  end
end
