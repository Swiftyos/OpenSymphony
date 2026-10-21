defmodule SymphonyElixir.RunSpecTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunSpec

  setup do
    previous = Application.get_env(:symphony_elixir, :state_root)
    root = Path.join(System.tmp_dir!(), "symphony-run-spec-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:symphony_elixir, :state_root, root)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :state_root)
        value -> Application.put_env(:symphony_elixir, :state_root, value)
      end

      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "write/read round-trips every field and rebuilds the Linear issue", %{root: root} do
    issue = %Issue{
      id: "issue-1",
      identifier: "MT-1",
      title: "A title",
      description: "A description",
      priority: 2,
      state: "In Progress",
      project_id: "project-1",
      project_slug: "checkout",
      project_name: "Checkout",
      branch_name: "mt-1",
      url: "https://example.org/MT-1",
      assignee_id: "user-1",
      labels: ["backend", "factory/implement"],
      assigned_to_worker: false,
      created_at: ~U[2026-01-01 00:00:00Z],
      updated_at: ~U[2026-01-02 00:00:00Z],
      blocked_by: [%{id: "b-1", identifier: "MT-0", state: "Todo"}]
    }

    spec = %RunSpec{
      run_id: "run-1",
      epoch: 4,
      attempt: 2,
      issue: issue,
      worker_host: "build-1",
      backend: "claude",
      effort: "high",
      account: %{backend: "claude", id: "acct-1"},
      controller_url: "http://127.0.0.1:4321",
      token: "token-1"
    }

    assert {:ok, path} = RunSpec.write(spec)
    assert path == RunSpec.path("run-1")
    assert path == Path.join([root, "runs", "run-1", "spec.json"])
    assert File.exists?(path)
    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600

    assert {:ok, %RunSpec{} = loaded} = RunSpec.read(path)
    assert loaded.run_id == "run-1"
    assert loaded.epoch == 4
    assert loaded.attempt == 2
    assert loaded.worker_host == "build-1"
    assert loaded.backend == "claude"
    assert loaded.effort == "high"
    assert loaded.account == %{backend: "claude", id: "acct-1"}
    assert loaded.controller_url == "http://127.0.0.1:4321"
    assert loaded.token == "token-1"

    assert %Issue{} = rebuilt = RunSpec.to_issue(loaded)
    assert rebuilt.id == issue.id
    assert rebuilt.identifier == issue.identifier
    assert rebuilt.labels == issue.labels
    assert rebuilt.created_at == issue.created_at
    assert rebuilt.updated_at == issue.updated_at
    assert rebuilt.blocked_by == [%{id: "b-1", identifier: "MT-0", state: "Todo"}]
  end

  test "an issue map without dates, and no account, also round-trips" do
    spec = %RunSpec{
      run_id: "run-2",
      epoch: 1,
      issue: %{id: "issue-2", identifier: "MT-2", labels: []},
      account: %{"backend" => "codex", "id" => "acct-2"}
    }

    assert {:ok, path} = RunSpec.write(spec)
    assert {:ok, loaded} = RunSpec.read(path)
    assert %Issue{id: "issue-2", identifier: "MT-2"} = RunSpec.to_issue(loaded)
    assert loaded.account == %{backend: "codex", id: "acct-2"}
    assert loaded.attempt == nil
  end

  test "read returns errors for a missing or malformed spec" do
    assert {:error, :enoent} = RunSpec.read(Path.join(System.tmp_dir!(), "missing-spec-#{System.unique_integer([:positive])}.json"))

    path = Path.join(System.tmp_dir!(), "bad-spec-#{System.unique_integer([:positive])}.json")
    File.write!(path, "not json")
    on_exit(fn -> File.rm(path) end)

    assert {:error, %Jason.DecodeError{}} = RunSpec.read(path)
  end

  test "write reports a filesystem error", %{root: root} do
    file = Path.join(root, "a-file")
    File.write!(file, "x")
    Application.put_env(:symphony_elixir, :state_root, file)

    assert {:error, _reason} = RunSpec.write(%RunSpec{run_id: "run-3", epoch: 1, issue: %{}})
  end

  test "controller_url uses the bound port and refuses a missing one" do
    assert RunSpec.controller_url(4321) == "http://127.0.0.1:4321"
    assert RunSpec.controller_url(0) == nil
    assert RunSpec.controller_url(nil) == nil

    case RunSpec.controller_url() do
      nil -> :ok
      url -> assert url =~ "http://127.0.0.1:"
    end
  end

  test "odd issues and accounts degrade to empty values" do
    spec = %RunSpec{
      run_id: "run-5",
      epoch: 1,
      issue: nil,
      account: %{something: "else"}
    }

    assert {:ok, path} = RunSpec.write(spec)
    assert {:ok, loaded} = RunSpec.read(path)
    assert %Issue{id: nil} = RunSpec.to_issue(loaded)
    assert loaded.account == nil

    # An issue that isn't a map decodes to an empty issue, and a Date encodes.
    weird = %{
      "run_id" => "run-6",
      "epoch" => 1,
      "issue" => "not a map",
      "account" => %{"not" => "an account"}
    }

    File.mkdir_p!(RunSpec.dir("run-6"))
    File.write!(RunSpec.path("run-6"), Jason.encode!(weird))
    assert {:ok, read} = RunSpec.read(RunSpec.path("run-6"))
    assert %Issue{id: nil} = RunSpec.to_issue(read)
    assert read.account == nil

    dated = %RunSpec{run_id: "run-7", epoch: 1, issue: %{id: "i", created_at: ~D[2026-01-01]}}
    assert {:ok, dated_path} = RunSpec.write(dated)
    assert {:ok, dated_read} = RunSpec.read(dated_path)
    assert %Issue{id: "i"} = RunSpec.to_issue(dated_read)
  end

  test "to_issue tolerates an empty issue map" do
    assert %Issue{id: nil, labels: [], blocked_by: []} = RunSpec.to_issue(%RunSpec{run_id: "run-4", epoch: 1, issue: %{}})
  end
end
