defmodule SymphonyElixir.ProjectRoutesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ProjectRoutes

  setup do
    ProjectRoutes.reset()
    on_exit(&ProjectRoutes.reset/0)
    :ok
  end

  test "routes are validated narrowly: GitHub repos, repo-relative workflows, no host paths" do
    good = %{"slug" => "0A1B2C3D4E5F", "repo" => "acme/widgets"}

    assert {:ok, %{slug: "0a1b2c3d4e5f", repo: "acme/widgets", workflow: nil, default_branch: "main", backend: nil, added_by: "ada"}} =
             ProjectRoutes.put(good, "ada")

    for {key, value, message} <- [
          {"slug", "../etc", "slug"},
          {"repo", "../../srv/symphony", "owner/name"},
          {"repo", "/srv/symphony/src/n8n", "owner/name"},
          {"repo", "https://evil.example/x.git", "owner/name"},
          {"workflow", "../WORKFLOW.md", "inside the repo"},
          {"workflow", "/etc/WORKFLOW.md", "inside the repo"},
          {"workflow", "~/WORKFLOW.md", "inside the repo"},
          {"workflow", "WORKFLOW.txt", "inside the repo"},
          {"default_branch", "main/../x", "branch"},
          {"default_branch", "-x", "branch"},
          {"backend", "gpt", "backend"}
        ] do
      assert {:error, error} = ProjectRoutes.put(Map.put(good, key, value), "ada"), "#{key}=#{value}"
      assert error =~ message
    end

    assert {:ok, %{workflow: ".symphony/WORKFLOW.md", default_branch: "master", backend: "claude"}} =
             ProjectRoutes.put(Map.merge(good, %{"workflow" => ".symphony/WORKFLOW.md", "default_branch" => "master", "backend" => "claude"}), "ada")

    assert [%{slug: "0a1b2c3d4e5f", default_branch: "master"}] = ProjectRoutes.list()
    assert :ok = ProjectRoutes.delete("0a1b2c3d4e5f")
    assert {:error, :not_found} = ProjectRoutes.delete("0a1b2c3d4e5f")
    assert {:error, :not_found} = ProjectRoutes.delete(nil)
  end

  test "a route can list more repos, each a GitHub repo with a unique name" do
    base = %{"slug" => "0a1b2c3d4e5f", "repo" => "acme/widgets"}

    assert {:ok, %{repos: [worker, %{name: "infra", default_branch: "trunk"}]}} =
             ProjectRoutes.put(
               Map.put(base, "repos", [
                 %{"name" => "Worker", "repo" => "acme/widgets-worker", "description" => "Jobs"},
                 %{"repo" => "acme/infra", "default_branch" => "trunk"}
               ]),
               "ada"
             )

    assert worker == %{name: "worker", repo: "acme/widgets-worker", default_branch: "main", description: "Jobs"}
    assert [%{repos: [%{name: "worker"}, %{name: "infra"}]}] = ProjectRoutes.tracker_projects()

    for {repos, message} <- [
          {[%{"repo" => "/srv/worker"}], "owner/name"},
          {[%{}], "owner/name"},
          {[%{"repo" => "acme/x", "description" => String.duplicate("x", 501)}], "longer than 500"},
          {[%{"repo" => "acme/widgets"}], "two repos named widgets"},
          {[%{"name" => "a", "repo" => "acme/a"}, %{"name" => "a", "repo" => "acme/b"}], "two repos named a"},
          {[%{"name" => "../x", "repo" => "acme/x"}], "repo names"},
          {[%{"repo" => "acme/x", "default_branch" => "-x"}], "branch"},
          {"acme/x", "list"},
          {["acme/x"], "object"}
        ] do
      assert {:error, error} = ProjectRoutes.put(Map.put(base, "repos", repos), "ada"), inspect(repos)
      assert error =~ message
    end
  end

  test "a route may name a catalog environment, and the name is validated" do
    good = %{"slug" => "envproject", "repo" => "acme/widgets"}

    assert {:ok, route} = ProjectRoutes.put(Map.put(good, "environment", "python"), "ada")
    assert route.environment == "python"

    assert %SymphonyElixir.Config.Schema.TrackerProject{environment: "python"} =
             Enum.find(ProjectRoutes.tracker_projects(), &(&1.slug == "envproject"))

    assert {:error, message} = ProjectRoutes.put(Map.put(good, "environment", "Bad/Name"), "ada")
    assert message =~ "environment"
  end

  test "routes are persisted, and re-validated on load" do
    dir = Path.join(System.tmp_dir!(), "project-routes-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "project_routes.json")
    on_exit(fn -> File.rm_rf(dir) end)
    restart_store(path)

    {:ok, _} = ProjectRoutes.put(%{"slug" => "9e8d7c6b5a40", "repo" => "acme/infra"}, "ada")
    body = File.read!(path)
    assert body =~ "acme/infra"

    routes = Jason.decode!(body)["routes"] ++ [%{"slug" => "bad1", "repo" => "/etc"}, "junk"]
    File.write!(path, Jason.encode!(%{version: 1, routes: routes}))
    log = capture_log(fn -> restart_store(path) end)
    assert log =~ "Project route skipped"
    assert [%{slug: "9e8d7c6b5a40", added_by: "ada"}] = ProjectRoutes.list()

    File.write!(path, "not json")
    assert capture_log(fn -> restart_store(path) end) =~ "Project route load failed"
    assert ProjectRoutes.list() == []

    restart_store("/dev/null/nope/project_routes.json")
    assert capture_log(fn -> {:ok, _} = ProjectRoutes.put(%{"slug" => "abc123", "repo" => "a/b"}, "ada") end) =~ "Project route save failed"
  end

  test "at most 100 stored routes; replacing one is always allowed" do
    for n <- 1..100, do: {:ok, _} = ProjectRoutes.put(%{"slug" => "p#{n}", "repo" => "a/b"}, "ada")
    assert {:error, message} = ProjectRoutes.put(%{"slug" => "p101", "repo" => "a/b"}, "ada")
    assert message =~ "100"
    assert {:ok, %{repo: "a/c"}} = ProjectRoutes.put(%{"slug" => "p1", "repo" => "a/c"}, "ada")
  end

  test "multi-project mode listens to stored routes after the file's; the file wins on a clash" do
    root = Path.join(System.tmp_dir!(), "project-routes-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    config_path = Path.join(root, "symphony.yml")

    write_symphony_config_file!(config_path,
      workspace_root: Path.join(root, "workspaces"),
      projects: [%{linear_project: "fromfile1", repo: "acme/gadgets", workflow: "WORKFLOW.md"}]
    )

    SymphonyConfig.set_config_file_path(config_path)

    {:ok, _} = ProjectRoutes.put(%{"slug" => "fromfile1", "repo" => "evil/repo"}, "ada")
    {:ok, _} = ProjectRoutes.put(%{"slug" => "stored1", "repo" => "acme/widgets", "backend" => "claude"}, "ada")

    assert [%{slug: "fromfile1", repo: "acme/gadgets"}, %{slug: "stored1", repo: "acme/widgets", backend: "claude", workspace_root: nil}] =
             Config.linear_project_routes()

    assert %{slug: "stored1"} = Config.linear_project_route(%{project_slug: "stored1"})
    assert Config.workspace_root_for_route(Config.linear_project_route(%{project_slug: "stored1"}), Config.settings!()) == Path.join([root, "workspaces", "stored1"])

    # Legacy single-project mode ignores stored routes.
    Application.put_env(:symphony_elixir, :startup_mode, :legacy)
    refute Enum.any?(Config.linear_project_routes(), &(&1.slug == "stored1"))
  end

  defp restart_store(path) do
    case Process.get(:route_store) do
      nil ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, ProjectRoutes)
        on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, ProjectRoutes) end)

      pid ->
        GenServer.stop(pid)
    end

    {:ok, pid} = ProjectRoutes.start_link(path: path)
    Process.put(:route_store, pid)
  end
end
