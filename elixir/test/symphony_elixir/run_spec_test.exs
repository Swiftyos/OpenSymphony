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

  test "delete removes only the spec, and is ok when it is already gone" do
    spec = %RunSpec{run_id: "run-delete", epoch: 1}
    assert {:ok, path} = RunSpec.write(spec)
    log = Path.join(RunSpec.dir("run-delete"), "runner.log")
    File.write!(log, "kept")

    assert :ok = RunSpec.delete("run-delete")
    refute File.exists?(path)
    assert File.read!(log) == "kept"
    assert :ok = RunSpec.delete("run-delete")
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
      project_route: %{
        slug: "checkout",
        repo: "acme/widgets",
        workflow: "WORKFLOW.md",
        backend: "claude",
        default_branch: "main",
        workspace_root: "/tmp/checkout"
      },
      workspace_root: "/tmp/checkout",
      route: %{backend: "claude", effort: "high", warnings: ["a warning"]},
      account: %{backend: "claude", id: "acct-1"},
      environment: %SymphonyElixir.Environment{
        name: "python",
        image: "registry.example.com/python:3.12",
        resources: %{"cpu" => 2, "memory" => "4g"},
        services: [%{name: "db", image: "registry.example.com/postgres:16", env: %{}, ports: ["5432"], command: []}],
        setup: ["pip install -r requirements.txt"],
        egress_extra: ["api.example.com"],
        digest: "digest-1",
        repo_file: true
      },
      controller_url: "http://127.0.0.1:4321",
      git_mirror_url: "http://127.0.0.1:4321/git/run-1/checkout-abc123",
      target_branch: "main",
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
    assert loaded.project_route.slug == "checkout"
    assert loaded.project_route.repo == "acme/widgets"
    assert loaded.project_route.workspace_root == "/tmp/checkout"
    assert loaded.workspace_root == "/tmp/checkout"
    assert loaded.route == %{backend: "claude", effort: "high", warnings: ["a warning"]}
    assert loaded.account == %{backend: "claude", id: "acct-1"}

    assert loaded.environment == %{
             "name" => "python",
             "image" => "registry.example.com/python:3.12",
             "resources" => %{"cpu" => 2, "memory" => "4g"},
             "services" => [%{"name" => "db", "image" => "registry.example.com/postgres:16", "env" => %{}, "ports" => ["5432"], "command" => []}],
             "setup" => ["pip install -r requirements.txt"],
             "egress_extra" => ["api.example.com"],
             "digest" => "digest-1",
             "repo_file" => true
           }

    assert loaded.controller_url == "http://127.0.0.1:4321"
    assert loaded.git_mirror_url == "http://127.0.0.1:4321/git/run-1/checkout-abc123"
    assert loaded.target_branch == "main"
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
      account: %{"backend" => "codex", "id" => "acct-2"},
      environment: %{"name" => "base", "image" => "registry.example.com/base:1"}
    }

    assert {:ok, path} = RunSpec.write(spec)
    assert {:ok, loaded} = RunSpec.read(path)
    assert %Issue{id: "issue-2", identifier: "MT-2"} = RunSpec.to_issue(loaded)
    assert loaded.account == %{backend: "codex", id: "acct-2"}
    assert loaded.environment == %{"name" => "base", "image" => "registry.example.com/base:1"}
    assert loaded.attempt == nil

    bad = %RunSpec{run_id: "run-bad-environment", epoch: 1, environment: "not-a-map"}
    assert {:ok, path} = RunSpec.write(bad)
    assert {:ok, %RunSpec{environment: nil}} = RunSpec.read(path)
  end

  test "project routes may be structs, and odd routes decode to nil", %{root: root} do
    route = %SymphonyElixir.Config.Schema.TrackerProject{
      slug: "checkout",
      repo: "acme/widgets",
      workflow: "WORKFLOW.md",
      backend: "codex",
      workspace_root: "/tmp/checkout",
      hooks: %{"after_create" => "make deps"},
      repos: [%SymphonyElixir.Config.Schema.TrackerProjectRepo{name: "worker", repo: "acme/jobs-worker", default_branch: "trunk"}]
    }

    spec = %RunSpec{
      run_id: "run-struct-route",
      epoch: 1,
      issue: %{},
      project_route: route,
      route: %SymphonyElixir.AgentRoute{backend: "codex", effort: "high", warnings: []}
    }

    assert {:ok, path} = RunSpec.write(spec)
    assert {:ok, loaded} = RunSpec.read(path)
    assert loaded.project_route.slug == "checkout"
    assert loaded.project_route.repo == "acme/widgets"
    assert loaded.project_route.hooks == %{"after_create" => "make deps"}
    # A multi-repo route keeps its repos, so a runner finds the issue's home repo.
    assert [%{name: "worker", repo: "acme/jobs-worker", default_branch: "trunk"}] = loaded.project_route.repos

    assert %{name: "worker", default_branch: "trunk"} =
             SymphonyElixir.Config.issue_repo_for_route(%{labels: ["repo/worker"]}, loaded.project_route)

    assert loaded.route == %{backend: "codex", effort: "high", warnings: []}

    File.mkdir_p!(RunSpec.dir("run-odd-route"))
    File.write!(RunSpec.path("run-odd-route"), Jason.encode!(%{"run_id" => "run-odd-route", "epoch" => 1, "project_route" => "nope", "route" => 7}))
    assert {:ok, odd} = RunSpec.read(RunSpec.path("run-odd-route"))
    assert odd.project_route == nil
    assert odd.route == nil
    _ = root
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
