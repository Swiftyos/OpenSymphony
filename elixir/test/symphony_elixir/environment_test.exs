defmodule SymphonyElixir.EnvironmentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Environment
  alias SymphonyElixir.Factory.{Definition, Store}
  alias SymphonyElixir.IssueConfig
  alias SymphonyElixir.Linear.Issue

  setup do
    Store.reset()
    on_exit(&Store.reset/0)

    root = Path.join(System.tmp_dir!(), "symphony-environment-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root}
  end

  defp settings(environments, teams \\ %{}) do
    assert {:ok, settings} = Schema.parse(%{"environments" => environments, "teams" => teams})
    settings
  end

  defp catalog do
    %{
      "default" => %{
        "image" => "registry.example.com/agents/base:1",
        "resources" => %{"cpu" => 4, "memory" => "8g"},
        "allowed_images" => ["registry.example.com/", "ghcr.io/acme/"],
        "egress_extra" => ["api.example.com"],
        "services" => [
          %{"name" => "cache", "image" => "registry.example.com/services/redis:7", "ports" => [6379]}
        ]
      },
      "python" => %{
        "image" => "registry.example.com/agents/python:3.12",
        "resources" => %{"cpu" => 8, "memory" => "16g"},
        "allowed_images" => ["registry.example.com/agents/"]
      },
      "team" => %{
        "image" => "registry.example.com/agents/team:1",
        "resources" => %{"cpu" => 2, "memory" => "2g"},
        "allowed_images" => ["registry.example.com/agents/"]
      },
      "stage" => %{
        "image" => "registry.example.com/agents/stage:1",
        "resources" => %{"cpu" => 1, "memory" => "1g"},
        "allowed_images" => ["registry.example.com/agents/"]
      }
    }
  end

  defp issue(identifier \\ "PAY-1", state \\ "In Progress", labels \\ []) do
    %Issue{id: "id-" <> identifier, identifier: identifier, title: "T", state: state, labels: labels, project_slug: "proj"}
  end

  defp route(environment) do
    %{slug: "proj", repo: nil, environment: environment, workspace_root: nil}
  end

  defp write_repo_file(root, contents) do
    File.mkdir_p!(Path.join(root, ".symphony"))
    path = Path.join([root, ".symphony", "environment.yaml"])
    File.write!(path, contents)
    path
  end

  test "configured?/1 and resolve_optional/3 keep today's behaviour without a catalog" do
    settings = settings(%{})

    refute Environment.configured?(settings)
    refute Environment.configured?(nil)
    assert {:ok, nil} = Environment.resolve_optional(issue(), settings)

    assert {:error, {:environments_not_configured, []}} = Environment.resolve(issue(), settings)
    assert Environment.format_error({:environments_not_configured, []}) =~ "no environments"
    assert Environment.format_error(:invalid_environment_settings) =~ "invalid environment settings"
    assert Environment.format_error(:other) == ":other"
  end

  test "the catalog default is used, and the digest is stable for the same content" do
    settings = settings(catalog())
    assert Environment.configured?(settings)

    assert {:ok, default} = Environment.resolve_optional(issue(), settings)
    assert default.name == "default"
    assert default.image == "registry.example.com/agents/base:1"
    assert default.resources == %{"cpu" => 4, "memory" => "8g"}
    assert default.egress_extra == ["api.example.com"]
    assert default.repo_file == false
    assert [%{name: "cache"}] = default.services

    assert {:ok, again} = Environment.resolve(issue(), settings)
    assert again.digest == default.digest

    map = Environment.to_map(default)
    assert map["image"] == default.image
    assert map["services"] == default.services
    assert map["digest"] == default.digest
  end

  test "team, project route, and stage override the default in that order" do
    settings = settings(catalog(), %{"PAY" => %{"environment" => "team"}})
    assert Config.team_environment("PAY", settings) == "team"
    assert Config.team_environment("pay", settings) == "team"
    assert Config.team_environment("OPS", settings) == nil
    assert Config.team_environment(nil, settings) == nil

    assert {:ok, %{name: "team"}} = Environment.resolve(issue(), settings)
    assert {:ok, %{name: "python"}} = Environment.resolve(issue(), settings, route: route("python"))

    definition = Definition.default_template()
    stages = Enum.map(definition["stages"], fn stage -> if stage["id"] == "implement", do: %{stage | "environment" => "stage"}, else: stage end)
    assert {:ok, _} = Store.put("PAY", %{definition | "stages" => stages}, 0, "test")

    assert {:ok, %{name: "stage"}} = Environment.resolve(issue(), settings, route: route("python"))

    assert {:error, {:unknown_environment, "missing", available}} =
             Environment.resolve(issue("OPS-1"), settings, route: route("missing"))

    assert available == ["default", "python", "stage", "team"]
    assert Environment.format_error({:unknown_environment, "missing", available}) =~ "not in the platform catalog"
  end

  test "a missing repo file keeps the catalog values", %{root: root} do
    settings = settings(catalog())

    assert {:ok, environment} = Environment.resolve(issue(), settings, route: route("python"), repo_root: root)
    assert environment.image == "registry.example.com/agents/python:3.12"
    assert environment.resources == %{"cpu" => 8, "memory" => "16g"}
    assert environment.repo_file == false
  end

  test "a repo file may lower resources, add setup, and override services within bounds", %{root: root} do
    write_repo_file(root, """
    image: registry.example.com/agents/python:3.13
    resources:
      cpu: 2
      memory: 4g
    setup:
      - "pip install -r requirements.txt"
      - "  "
    services:
      - name: cache
        image: ghcr.io/acme/redis:7.2
        env:
          REDIS_PASSWORD: secret
        ports: [6379]
        command: redis-server --requirepass secret
    """)

    settings = settings(catalog())

    assert {:ok, environment} = Environment.resolve(issue(), settings, route: route("default"), repo_root: root)
    assert environment.image == "registry.example.com/agents/python:3.13"
    assert environment.resources == %{"cpu" => 2, "memory" => "4g"}
    assert environment.setup == ["pip install -r requirements.txt"]
    assert environment.repo_file == true

    assert [%{name: "cache", image: "ghcr.io/acme/redis:7.2", env: %{"REDIS_PASSWORD" => "secret"}, ports: ["6379"], command: ["sh", "-lc", "redis-server --requirepass secret"]}] =
             environment.services

    write_repo_file(root, "image: registry.example.com/agents/python:3.12\n")
    assert {:ok, other} = Environment.resolve(issue(), settings, route: route("default"), repo_root: root)
    assert other.digest != environment.digest
  end

  test "repo images must match the catalog's allowed prefixes", %{root: root} do
    write_repo_file(root, "image: docker.io/library/node:22\n")
    settings = settings(catalog())

    assert {:error, {:invalid_repo_environment, path, message}} =
             Environment.resolve(issue(), settings, route: route("default"), repo_root: root)

    assert message =~ "not allowed"
    assert Environment.format_error({:invalid_repo_environment, path, message}) =~ "repository environment"
  end

  test "repo resources may not exceed or introduce unbounded limits", %{root: root} do
    settings = settings(catalog())

    for {yaml, message} <- [
          {"resources:\n  cpu: 9\n", "exceeds"},
          {"resources:\n  memory: 17g\n", "exceeds"},
          {"resources:\n  cpu: 2\n  memory: 4g\n  disk: 10g\n", "unknown resources"},
          {"resources:\n  cpu: -1\n", "positive number"},
          {"resources:\n  memory: huge\n", "size such as"},
          {"resources:\n  gpu: 1\n", "unknown resources"}
        ] do
      write_repo_file(root, yaml)

      assert {:error, {:invalid_repo_environment, _path, actual}} =
               Environment.resolve(issue(), settings, route: route("default"), repo_root: root),
             yaml

      assert actual =~ message
    end

    write_repo_file(root, "resources:\n  cpu: 2\n")
    tight = settings(%{"tight" => %{"image" => "registry.example.com/tight:1"}})

    assert {:error, {:invalid_repo_environment, _path, message}} =
             Environment.resolve(issue(), tight, route: route("tight"), repo_root: root)

    assert message =~ "not bounded"
  end

  test "repo services are validated: image, keys, env, ports, command, and duplicates", %{root: root} do
    settings = settings(catalog())

    for {yaml, message} <- [
          {"services: nope\n", "services must be a list"},
          {"services:\n  - name: db\n    image: docker.io/postgres:16\n", "not allowed"},
          {"services:\n  - name: db\n    image: registry.example.com/postgres:16\n    volume: x\n", "unknown service keys"},
          {"services:\n  - image: registry.example.com/postgres:16\n", "needs a name"},
          {"services:\n  - name: Bad_Name\n    image: registry.example.com/postgres:16\n", "service name"},
          {"services:\n  - name: db\n", "needs an image"},
          {"services:\n  - name: db\n    image: '  '\n", "must not be blank"},
          {"services:\n  - name: db\n    image: registry.example.com/postgres:16\n    env: [x]\n", "env must be a map"},
          {"services:\n  - name: db\n    image: registry.example.com/postgres:16\n    env:\n      BAD-NAME: x\n", "shell identifiers"},
          {"services:\n  - name: db\n    image: registry.example.com/postgres:16\n    env:\n      GOOD: 1\n", "must be a string"},
          {"services:\n  - name: db\n    image: registry.example.com/postgres:16\n    ports: nope\n", "ports must be a list"},
          {"services:\n  - name: db\n    image: registry.example.com/postgres:16\n    ports: [0]\n", "port numbers"},
          {"services:\n  - name: db\n    image: registry.example.com/postgres:16\n    ports: ['']\n", "port numbers"},
          {"services:\n  - name: db\n    image: registry.example.com/postgres:16\n    command: [1]\n", "command must be"},
          {"services:\n  - name: db\n    image: registry.example.com/postgres:16\n  - name: db\n    image: registry.example.com/postgres:16\n", "duplicate"},
          {"services:\n  - nope\n", "each service must be a map"}
        ] do
      write_repo_file(root, yaml)

      assert {:error, {:invalid_repo_environment, _path, actual}} =
               Environment.resolve(issue(), settings, route: route("default"), repo_root: root),
             yaml

      assert actual =~ message
    end

    write_repo_file(root, "services:\n  - name: db\n    image: registry.example.com/postgres:16\n    command: ''\n")

    assert {:ok, environment} = Environment.resolve(issue(), settings, route: route("default"), repo_root: root)
    assert Enum.any?(environment.services, &(&1.name == "db" and &1.command == []))
  end

  test "unknown repo keys, bad setup, invalid YAML, and unreadable files fail closed", %{root: root} do
    settings = settings(catalog())

    for {yaml, message} <- [
          {"network: host\n", "unknown keys"},
          {"setup: nope\n", "setup must be a list"},
          {"setup:\n  - 1\n", "setup must be a list of commands"},
          {"services: [\n", "not valid YAML"},
          {"- just\n- a list\n", "must be a map"}
        ] do
      write_repo_file(root, yaml)

      assert {:error, {:invalid_repo_environment, _path, actual}} =
               Environment.resolve(issue(), settings, route: route("default"), repo_root: root),
             yaml

      assert actual =~ message
    end

    path = Path.join([root, ".symphony", "environment.yaml"])
    File.rm!(path)
    File.mkdir_p!(path)

    assert {:error, {:repo_environment_unreadable, ^path, _reason}} =
             Environment.resolve(issue(), settings, route: route("default"), repo_root: root)

    assert Environment.format_error({:repo_environment_unreadable, path, :eisdir}) =~ "unreadable"
  end

  test "invalid catalog entries are rejected with a clear reason" do
    for {entry, message} <- [
          {"nope", "must be a map"},
          {%{}, "needs an image"},
          {%{"image" => "  "}, "needs an image"},
          {%{"image" => "x", "resources" => "nope"}, "resources must be a map"},
          {%{"image" => "x", "resources" => %{"cpu" => 0}}, "positive cpu"},
          {%{"image" => "x", "resources" => %{"memory" => "nope"}}, "positive cpu"},
          {%{"image" => "x", "resources" => %{"gpu" => 1}}, "positive cpu"},
          {%{"image" => "x", "services" => "nope"}, "services must be a list"},
          {%{"image" => "x", "services" => [%{"name" => "Bad", "image" => "ok"}]}, "service name"},
          {%{"image" => "x", "services" => [%{"name" => "ok"}]}, "needs an image"}
        ] do
      settings = %{settings(%{}) | environments: %{"default" => entry}}

      assert {:error, {:invalid_environment_catalog, "default", actual}} = Environment.resolve(issue(), settings)
      assert actual =~ message
      assert Environment.format_error({:invalid_environment_catalog, "default", actual}) =~ "catalog environment"
    end
  end

  test "catalog services may use any image and repo services merge by name", %{root: root} do
    catalog = %{
      "default" => %{
        "image" => "registry.example.com/base:1",
        "resources" => %{"cpu" => 1, "memory" => "1g"},
        "allowed_images" => ["registry.example.com/allowed/"],
        "services" => [
          %{"name" => "cache", "image" => "docker.io/redis:7"},
          %{"name" => "db", "image" => "docker.io/postgres:16"}
        ]
      }
    }

    write_repo_file(root, """
    services:
      - name: cache
        image: registry.example.com/allowed/redis:7.2
    """)

    assert {:ok, environment} = Environment.resolve(issue(), settings(catalog), route: route("default"), repo_root: root)

    assert [
             %{name: "cache", image: "registry.example.com/allowed/redis:7.2"},
             %{name: "db", image: "docker.io/postgres:16"}
           ] = environment.services
  end

  test "repo file edge cases are parsed strictly", %{root: root} do
    settings = settings(catalog())

    for {yaml, _expected} <- [
          {"", :ok},
          {"null\n", :ok},
          {"# comment\n", :ok},
          {"image: ''\n", :ok},
          {"resources:\n  cpu: '2'\n  memory: 4096\n", :ok},
          {"services:\n  - name: worker\n    image: registry.example.com/worker:1\n    ports: ['8080']\n    command: [node, worker.js]\n", :ok}
        ] do
      write_repo_file(root, yaml)
      assert match?({:ok, _}, Environment.resolve(issue(), settings, route: route("default"), repo_root: root)), yaml
    end

    write_repo_file(root, "services:\n  - name: worker\n    image: registry.example.com/worker:1\n    ports: ['8080']\n    command: [node, worker.js]\n")
    assert {:ok, environment} = Environment.resolve(issue(), settings, route: route("default"), repo_root: root)
    worker = Enum.find(environment.services, &(&1.name == "worker"))
    assert worker.ports == ["8080"]
    assert worker.command == ["node", "worker.js"]

    for {yaml, message} <- [
          {"image: [x]\n", "image must be a string"},
          {"resources: [x]\n", "resources must be a map"},
          {"resources:\n  cpu: 'abc'\n", "positive number"},
          {"resources:\n  memory: [1]\n", "size such as"},
          {"services:\n  - name: worker\n    image: [x]\n", "needs an image"},
          {"services:\n  - name: worker\n    image: registry.example.com/worker:1\n    command: 1\n", "command must be"}
        ] do
      write_repo_file(root, yaml)

      assert {:error, {:invalid_repo_environment, _path, actual}} =
               Environment.resolve(issue(), settings, route: route("default"), repo_root: root),
             yaml

      assert actual =~ message
    end
  end

  test "memory units and an unbounded catalog are handled", %{root: root} do
    settings = settings(%{"big" => %{"image" => "registry.example.com/big:1", "resources" => %{"memory" => "2t"}}})

    for memory <- ["1k", "1m", "1t", "1b"] do
      write_repo_file(root, "resources:\n  memory: #{memory}\n")
      assert {:ok, environment} = Environment.resolve(issue(), settings, route: route("big"), repo_root: root)
      assert environment.resources["memory"] == memory
    end
  end

  test "a catalog without a default and no overrides fails, and non-map inputs are ignored", %{root: root} do
    settings = settings(%{"python" => %{"image" => "registry.example.com/python:1"}})

    assert {:error, {:unknown_environment, nil, ["python"]}} = Environment.resolve(issue(), settings)
    assert {:error, {:unknown_environment, nil, ["python"]}} = Environment.resolve(issue("PAY-1", "Unknown"), settings)
    assert {:error, :invalid_environment_settings} = Environment.resolve(issue(), nil)
    assert {:error, {:environments_not_configured, []}} = Environment.resolve(issue(), %{settings | environments: "nope"})

    # An allowed image list that is not a list grants nothing.
    catalog = %{"default" => %{"image" => "registry.example.com/base:1", "allowed_images" => "registry.example.com/"}}
    settings = %{settings(%{}) | environments: catalog}
    write_repo_file(root, "image: registry.example.com/other:1\n")

    assert {:error, {:invalid_repo_environment, _path, message}} =
             Environment.resolve(issue(), settings, route: route("default"), repo_root: root)

    assert message =~ "allowed_images (none)"
  end

  test "a route with a local repo fetches its cache to read the repo file", %{root: root} do
    repo = Path.join(root, "repo")
    File.mkdir_p!(Path.join(repo, ".symphony"))
    File.write!(Path.join([repo, ".symphony", "environment.yaml"]), "resources:\n  cpu: 1\n")
    System.cmd("git", ["init", "-q", "-b", "main", repo])
    System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", repo, "config", "user.name", "Test"])
    System.cmd("git", ["-C", repo, "add", "."])
    System.cmd("git", ["-C", repo, "commit", "-qm", "init"])

    settings =
      settings(catalog())
      |> Map.put(:workspace, %{settings(catalog()).workspace | root: Path.join(root, "workspaces")})

    route = %{slug: "proj", repo: repo, environment: "default", workspace_root: nil, default_branch: "main"}

    assert {:ok, environment} = Environment.resolve(issue(), settings, route: route)
    assert environment.repo_file == true
    assert environment.resources["cpu"] == 1
  end

  test "IssueConfig applies the environment to the run's settings and fails closed", %{root: root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    previous = Application.get_env(:symphony_elixir, :startup_mode)
    Application.put_env(:symphony_elixir, :startup_mode, :legacy)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :startup_mode, previous),
        else: Application.delete_env(:symphony_elixir, :startup_mode)
    end)

    settings = settings(catalog(), %{"PAY" => %{"environment" => "team"}})

    assert {:ok, issue_config} = IssueConfig.resolve(issue(), settings: settings)
    assert issue_config.environment.name == "team"
    assert issue_config.settings.sandbox.environment.name == "team"

    bad = settings(catalog(), %{"PAY" => %{"environment" => "missing"}})

    assert {:error, {:environment_invalid, "PAY-1", message}} = IssueConfig.resolve(issue(), settings: bad)
    assert message =~ "not in the platform catalog"

    routed = settings(catalog())

    route = %SymphonyElixir.Config.Schema.TrackerProject{slug: "proj", environment: "missing"}
    routed = %{routed | tracker: %{routed.tracker | projects: [route]}}

    assert {:error, {:environment_invalid, "PAY-1", _message}} =
             IssueConfig.resolve(%{"identifier" => "PAY-1", "project_slug" => "proj"}, settings: routed)

    no_default = settings(%{"only" => %{"image" => "registry.example.com/only:1"}})

    assert {:error, {:environment_invalid, nil, _message}} =
             IssueConfig.resolve(%{}, settings: no_default)
  end

  test "a route without a repo, or with a repo_root override, does not fetch a cache" do
    settings = settings(catalog())

    assert {:ok, %{repo_file: false}} =
             Environment.resolve(issue(), settings, route: %{slug: "proj", repo: nil, environment: "default"})
  end
end
