defmodule SymphonyElixir.RunRegistryServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunLauncher.Local
  alias SymphonyElixir.RunRegistry
  alias SymphonyElixir.RunRegistry.Server

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-run-registry-server-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "runs.json")
    Application.put_env(:symphony_elixir, :runs_path, path)

    on_exit(fn ->
      RunRegistry.flush()
      Application.put_env(:symphony_elixir, :runs_path, nil)
      File.rm_rf(root)
    end)

    %{path: path}
  end

  test "concurrent writers from many processes lose no record, delete or progress", %{path: path} do
    issues = for n <- 1..40, do: "issue-#{n}"

    issues
    |> Enum.map(fn issue_id -> Task.async(fn -> RunRegistry.record(issue_id, entry(issue_id)) end) end)
    |> Enum.each(&Task.await/1)

    # Progress, finished and deletes race each other across processes.
    issues
    |> Enum.with_index()
    |> Enum.map(fn {issue_id, index} ->
      Task.async(fn ->
        case rem(index, 3) do
          0 -> RunRegistry.delete(issue_id)
          1 -> RunRegistry.advance_progress(issue_id, "run-" <> issue_id, index)
          2 -> RunRegistry.advance_progress(issue_id, "run-" <> issue_id, index, "normal")
        end
      end)
    end)
    |> Enum.each(&Task.await/1)

    :ok = RunRegistry.flush()
    on_disk = disk_runs(path)

    for {issue_id, index} <- Enum.with_index(issues) do
      case rem(index, 3) do
        0 ->
          refute Map.has_key?(on_disk, issue_id)

        1 ->
          assert %{"last_seq" => ^index, "finished" => nil} = on_disk[issue_id]

        2 ->
          assert %{"last_seq" => ^index, "finished" => "normal"} = on_disk[issue_id]
      end
    end

    assert path |> File.read!() |> Jason.decode!() |> Map.fetch!("epochs") |> map_size() == 40
  end

  test "progress is visible at once, written once a second, and a finished reason is written before it returns", %{path: path} do
    :ok = RunRegistry.record("issue-1", entry("issue-1"))

    assert :ok = RunRegistry.advance_progress("issue-1", "run-issue-1", 3)
    assert :ok = RunRegistry.advance_progress("issue-1", "run-issue-1", 2)
    assert RunRegistry.load()["issue-1"].last_seq == 3
    assert disk_runs(path)["issue-1"]["last_seq"] == 0
    assert Server.pending(path) == %{"issue-1" => {"run-issue-1", 3}}

    # The coalesced write lands within the flush interval.
    Process.sleep(1_300)
    assert disk_runs(path)["issue-1"]["last_seq"] == 3
    assert Server.pending(path) == %{}

    # A finished reason is durable when the call returns, with pending progress.
    assert :ok = RunRegistry.advance_progress("issue-1", "run-issue-1", 5)
    assert :ok = RunRegistry.advance_progress("issue-1", "run-issue-1", 4, "normal")
    assert %{"last_seq" => 5, "finished" => "normal"} = disk_runs(path)["issue-1"]
  end

  test "buffered progress never brings back a deleted run, and a new run's progress replaces the old one's", %{path: path} do
    :ok = RunRegistry.record("issue-1", entry("issue-1"))
    :ok = RunRegistry.advance_progress("issue-1", "run-issue-1", 9)
    :ok = RunRegistry.delete("issue-1")
    :ok = RunRegistry.flush()
    assert disk_runs(path) == %{}

    :ok = RunRegistry.record("issue-2", entry("issue-2"))
    :ok = RunRegistry.advance_progress("issue-2", "old-run", 7)
    :ok = RunRegistry.advance_progress("issue-2", "run-issue-2", 2)
    assert Server.pending(path) == %{"issue-2" => {"run-issue-2", 2}}
    # Progress for another run is not shown either.
    :ok = RunRegistry.advance_progress("issue-2", "old-run", 8)
    assert RunRegistry.load()["issue-2"].last_seq == 0
    :ok = RunRegistry.flush()
    assert disk_runs(path)["issue-2"]["last_seq"] == 0
  end

  test "pending progress is written when the server shuts down, and writes go direct without it", %{path: path} do
    :ok = RunRegistry.record("issue-1", entry("issue-1"))
    :ok = RunRegistry.advance_progress("issue-1", "run-issue-1", 4)
    send(Process.whereis(Server), :unexpected)

    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Server)

    try do
      assert disk_runs(path)["issue-1"]["last_seq"] == 4

      # Without the server every write is applied by the caller.
      assert :ok = RunRegistry.advance_progress("issue-1", "run-issue-1", 6)
      assert disk_runs(path)["issue-1"]["last_seq"] == 6
      assert :ok = RunRegistry.record("issue-2", entry("issue-2"))
      assert :ok = RunRegistry.delete("issue-1")
      assert Map.keys(disk_runs(path)) == ["issue-2"]
      assert Server.pending(path) == %{}
      assert :ok = RunRegistry.flush()

      # A server that dies mid-call also falls back to the caller.
      dying =
        spawn(fn ->
          receive do
            _message -> exit(:boom)
          end
        end)

      Process.register(dying, Server)
      assert :ok = RunRegistry.advance_progress("issue-2", "run-issue-2", 1)
      assert disk_runs(path)["issue-2"]["last_seq"] == 1
    after
      if pid = Process.whereis(Server), do: Process.exit(pid, :kill)
      eventually_unregistered(Server)
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, Server)
    end
  end

  defp eventually_unregistered(name, attempts \\ 50) do
    if Process.whereis(name) && attempts > 0 do
      Process.sleep(10)
      eventually_unregistered(name, attempts - 1)
    end
  end

  defp disk_runs(path) do
    case File.read(path) do
      {:ok, body} -> body |> Jason.decode!() |> Map.get("runs", %{})
      {:error, :enoent} -> %{}
    end
  end

  defp entry(issue_id) do
    %{
      run_id: "run-" <> issue_id,
      attempt: 0,
      epoch: 1,
      launcher: Local,
      ref: "local:boot:0.1.0",
      started_at_unix_ms: 1_700_000_000_000,
      metadata: %{identifier: issue_id}
    }
  end
end
