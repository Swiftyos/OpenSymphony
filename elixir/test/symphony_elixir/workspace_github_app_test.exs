# credo:disable-for-this-file Credo.Check.Readability.MaxLineLength
defmodule SymphonyElixir.WorkspaceGitHubAppTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  @token "ghs_" <> String.duplicate("w", 36)

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-github-app-#{System.unique_integer([:positive])}")
    source_repo = Path.join(test_root, "source")
    hooks_dir = Path.join(test_root, "hooks")
    env_trace = Path.join(test_root, "env.trace")
    ps_trace = Path.join(test_root, "ps.trace")
    workspace_root = Path.join(test_root, "workspaces")

    File.mkdir_p!(source_repo)
    File.write!(Path.join(source_repo, "README.md"), "hello\n")
    System.cmd("git", ["-C", source_repo, "init", "-q", "-b", "main"])
    System.cmd("git", ["-C", source_repo, "-c", "user.name=T", "-c", "user.email=t@example.com", "add", "README.md"])
    System.cmd("git", ["-C", source_repo, "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "initial"])

    # Every ref update during clone/fetch runs this hook in git's environment, so
    # it records exactly what the workspace script handed to git, plus every
    # process's argv at that moment.
    File.mkdir_p!(hooks_dir)
    hook = Path.join(hooks_dir, "reference-transaction")

    File.write!(hook, """
    #!/bin/sh
    env | grep -E '^(GH_TOKEN|GIT_CONFIG_|GIT_TERMINAL_PROMPT)' >> "#{env_trace}"
    ps -A -o args= >> "#{ps_trace}" 2>/dev/null || true
    """)

    File.chmod!(hook, 0o755)

    global_config = Path.join(test_root, "gitconfig")

    File.write!(global_config, """
    [url "#{source_repo}"]
      insteadOf = https://github.com/octo/repo.git
    [core]
      hooksPath = #{hooks_dir}
    """)

    previous = for name <- ["GIT_CONFIG_GLOBAL", "GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR", "PATH"], into: %{}, do: {name, System.get_env(name)}
    previous_req_options = Application.get_env(:symphony_elixir, :github_app_req_options)

    System.put_env("GIT_CONFIG_GLOBAL", global_config)
    System.delete_env("GH_TOKEN")
    System.delete_env("GITHUB_TOKEN")
    File.mkdir_p!(Path.join(test_root, "gh-config"))
    System.put_env("GH_CONFIG_DIR", Path.join(test_root, "gh-config"))

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      if previous_req_options,
        do: Application.put_env(:symphony_elixir, :github_app_req_options, previous_req_options),
        else: Application.delete_env(:symphony_elixir, :github_app_req_options)

      File.rm_rf(test_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_projects: [%{slug: "project-a", repo: "octo/repo"}],
      workspace_root: workspace_root
    )

    {:ok, test_root: test_root, env_trace: env_trace, ps_trace: ps_trace}
  end

  defp app_settings(app_id) do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])

    Application.put_env(:symphony_elixir, :github_app_req_options, plug: fn conn -> Req.Test.json(conn, %{"token" => @token, "expires_at" => "2999-01-01T00:00:00Z"}) end)

    %{
      Config.settings!()
      | github_app: %Schema.GitHubApp{
          app_id: app_id,
          private_key: pem,
          installation_id: 1,
          base_url: "https://api.github.com",
          permissions: SymphonyElixir.GitHubApp.default_permissions()
        }
    }
  end

  defp read_trace(path), do: if(File.exists?(path), do: File.read!(path), else: "")

  test "repo cache sync and workspace clone get the token through the environment only", ctx do
    settings = app_settings(System.unique_integer([:positive]))
    issue = %Issue{identifier: "GHA-1", project_slug: "project-a"}

    assert {:ok, workspace} = Workspace.create_for_issue(issue, nil, settings: settings)
    assert File.read!(Path.join(workspace, "README.md")) == "hello\n"

    env = read_trace(ctx.env_trace)
    assert env =~ "GH_TOKEN=#{@token}"
    assert env =~ "GIT_CONFIG_KEY_0=http.https://github.com/.extraHeader"
    assert env =~ "GIT_TERMINAL_PROMPT=0"

    # Never in any process's argv, nor in the cache's or the workspace's git config.
    assert read_trace(ctx.ps_trace) != ""
    refute read_trace(ctx.ps_trace) =~ @token
    refute read_trace(ctx.ps_trace) =~ Base.encode64("x-access-token:" <> @token)

    cache_repo = Path.join([Config.workspace_root_for_issue(issue), ".symphony-cache", Config.project_repo_source_for_issue(issue).cache_key])

    for repo <- [cache_repo, workspace] do
      config = File.read!(Path.join([repo, ".git", "config"]))
      refute config =~ @token
      refute config =~ "extraheader"
    end

    # (The workspace copies `remote get-url`, which this test's insteadOf rewrites.)
    assert File.read!(Path.join([cache_repo, ".git", "config"])) =~ "url = https://github.com/octo/repo.git"
  end

  test "a token failure falls back to the gh login path and logs the reason", ctx do
    settings = app_settings(System.unique_integer([:positive]))
    Application.put_env(:symphony_elixir, :github_app_req_options, plug: fn conn -> Plug.Conn.send_resp(conn, 401, "{}") end)
    [route] = Config.linear_project_routes(settings)

    log =
      capture_log(fn ->
        assert {:error, _reason} = Workspace.ensure_local_repo_cache(route, settings)
      end)

    assert log =~ "GitHub App token unavailable repo=octo/repo reason=:unauthorized"
    assert log =~ "GitHub CLI"
    refute read_trace(ctx.env_trace) =~ "GH_TOKEN"
  end

  test "without github_app the sync keeps requiring the gh login", ctx do
    [route] = Config.linear_project_routes(Config.settings!())

    log =
      capture_log(fn ->
        assert {:error, _reason} = Workspace.ensure_local_repo_cache(route, Config.settings!())
      end)

    # The empty GH_CONFIG_DIR has no login, so the unchanged gh checks stop the sync.
    assert log =~ "GitHub CLI"
    refute log =~ "GitHub App"
    assert read_trace(ctx.env_trace) == ""
  end

  test "a remote worker gets the token over ssh stdin, not argv", ctx do
    settings = app_settings(System.unique_integer([:positive]))
    fake_bin = Path.join(ctx.test_root, "bin")
    ssh_trace = Path.join(ctx.test_root, "ssh.trace")
    File.mkdir_p!(fake_bin)

    # Runs the "remote" command locally; records the ssh argv.
    File.write!(Path.join(fake_bin, "ssh"), """
    #!/bin/sh
    printf '%s\\n' "$*" >> "#{ssh_trace}"
    for last; do :; done
    exec sh -c "$last"
    """)

    File.chmod!(Path.join(fake_bin, "ssh"), 0o755)
    System.put_env("PATH", fake_bin <> ":" <> System.get_env("PATH"))

    issue = %Issue{identifier: "GHA-2", project_slug: "project-a"}
    _result = Workspace.create_for_issue(issue, "worker-1", settings: settings)

    assert read_trace(ctx.env_trace) =~ "GH_TOKEN=#{@token}"
    assert read_trace(ssh_trace) =~ "bash -s"
    refute read_trace(ssh_trace) =~ @token
  end

  test "a GitHub Enterprise app authenticates against, and clones from, its own host", ctx do
    settings = app_settings(System.unique_integer([:positive]))
    settings = %{settings | github_app: %{settings.github_app | base_url: "https://ghe.example.com/api/v3"}}

    File.write!(Path.join(ctx.test_root, "gitconfig"), """
    [url "#{Path.join(ctx.test_root, "source")}"]
      insteadOf = https://ghe.example.com/octo/repo.git
    [core]
      hooksPath = #{Path.join(ctx.test_root, "hooks")}
    """)

    issue = %Issue{identifier: "GHA-3", project_slug: "project-a"}
    assert {:ok, workspace} = Workspace.create_for_issue(issue, nil, settings: settings)
    assert File.read!(Path.join(workspace, "README.md")) == "hello\n"

    env = read_trace(ctx.env_trace)
    assert env =~ "GIT_CONFIG_KEY_0=http.https://ghe.example.com/.extraHeader"
    refute env =~ "http.https://github.com/"

    cache_repo = Path.join([Config.workspace_root_for_issue(issue), ".symphony-cache", Config.project_repo_source_for_issue(issue).cache_key])
    config = File.read!(Path.join([cache_repo, ".git", "config"]))
    assert config =~ "url = https://ghe.example.com/octo/repo.git"
    refute config =~ "github.com"
  end

  test "a local sync appends its header to an inherited GIT_CONFIG_COUNT", ctx do
    settings = app_settings(System.unique_integer([:positive]))
    previous = for name <- ["GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"], into: %{}, do: {name, System.get_env(name)}

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env("GIT_CONFIG_COUNT", "1")
    System.put_env("GIT_CONFIG_KEY_0", "symphony.inherited")
    System.put_env("GIT_CONFIG_VALUE_0", "yes")

    issue = %Issue{identifier: "GHA-4", project_slug: "project-a"}
    assert {:ok, _workspace} = Workspace.create_for_issue(issue, nil, settings: settings)

    env = read_trace(ctx.env_trace)
    assert env =~ "GIT_CONFIG_COUNT=2"
    assert env =~ "GIT_CONFIG_KEY_0=symphony.inherited"
    assert env =~ "GIT_CONFIG_KEY_1=http.https://github.com/.extraHeader"
  end

  test "cache syncs for the home repo and the reference repos ask for read-only tokens", ctx do
    worker_repo = Path.join(ctx.test_root, "worker-source")
    File.mkdir_p!(worker_repo)
    File.write!(Path.join(worker_repo, "README.md"), "worker\n")
    System.cmd("git", ["-C", worker_repo, "init", "-q", "-b", "main"])
    System.cmd("git", ["-C", worker_repo, "-c", "user.name=T", "-c", "user.email=t@example.com", "add", "README.md"])
    System.cmd("git", ["-C", worker_repo, "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "initial"])

    File.write!(Path.join(ctx.test_root, "gitconfig"), """
    [url "#{Path.join(ctx.test_root, "source")}"]
      insteadOf = https://github.com/octo/repo.git
    [url "#{worker_repo}"]
      insteadOf = https://github.com/octo/worker.git
    [core]
      hooksPath = #{Path.join(ctx.test_root, "hooks")}
    """)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_projects: [%{slug: "project-a", repo: "octo/repo", repos: [%{name: "worker", repo: "octo/worker"}]}],
      workspace_root: Path.join(ctx.test_root, "workspaces")
    )

    settings = app_settings(System.unique_integer([:positive]))
    parent = self()

    Application.put_env(:symphony_elixir, :github_app_req_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:minted, Jason.decode!(body)})
        Req.Test.json(conn, %{"token" => @token, "expires_at" => "2999-01-01T00:00:00Z"})
      end
    )

    issue = %Issue{identifier: "GHA-5", project_slug: "project-a", labels: []}
    assert {:ok, workspace} = Workspace.create_for_issue(issue, nil, settings: settings)
    assert File.read!(Path.join(workspace, "README.md")) == "hello\n"
    assert File.read!(Path.join(workspace, ".symphony/repos/worker/README.md")) == "worker\n"

    read_only = %{"contents" => "read", "metadata" => "read"}
    assert_received {:minted, %{"repositories" => ["repo"], "permissions" => ^read_only}}
    assert_received {:minted, %{"repositories" => ["worker"], "permissions" => ^read_only}}
    refute_received {:minted, _}
  end
end
