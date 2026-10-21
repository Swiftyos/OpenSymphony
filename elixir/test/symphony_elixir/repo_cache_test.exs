defmodule SymphonyElixir.RepoCacheTest do
  use SymphonyElixir.TestSupport

  # Real git/process/HTTP integration; excluded by `make test-fast`.
  @moduletag :slow

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{RepoCacheLock, RepoCacheRefresher}
  alias SymphonyElixirWeb.PrometheusMetrics

  test "workspace starts inside the freshness window reuse the cache without fetching" do
    test_root = temp_root!("freshness-window")
    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      init_repo!(source_repo, "v1\n")
      write_repo_workflow!(workspace_root, source_repo)

      issue = fn identifier -> %Issue{identifier: identifier, project_slug: "project-a"} end

      assert {:ok, first_workspace} = Workspace.create_for_issue(issue.("PI-1"))
      assert File.read!(Path.join(first_workspace, "README.md")) == "v1\n"

      cache_repo = cache_repo_for(issue.("PI-1"))
      fetched_at_marker = Path.join([cache_repo, ".git", "symphony-fetched-at"])
      assert File.regular?(fetched_at_marker)

      commit_file!(source_repo, "README.md", "v2\n", "upstream v2")

      # A second workspace for the same repo starts within the window, so it sees
      # the cache's v1 rather than the new upstream commit.
      assert {:ok, second_workspace} = Workspace.create_for_issue(issue.("PI-2"))
      assert File.read!(Path.join(second_workspace, "README.md")) == "v1\n"

      # Once the marker is older than max_age_ms the next start fetches again.
      File.write!(fetched_at_marker, "0\n")

      assert {:ok, third_workspace} = Workspace.create_for_issue(issue.("PI-3"))
      assert File.read!(Path.join(third_workspace, "README.md")) == "v2\n"

      # The cache's own branch follows the fetched remote head, so a runner
      # cloning the cache mirror sees the same default branch.
      {cache_main, 0} = System.cmd("git", ["-C", cache_repo, "rev-parse", "refs/heads/main"])
      {source_main, 0} = System.cmd("git", ["-C", source_repo, "rev-parse", "refs/heads/main"])
      assert cache_main == source_main
    after
      File.rm_rf(test_root)
    end
  end

  test "max_age_ms 0 always fetches from the remote" do
    test_root = temp_root!("always-fetch")
    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      init_repo!(source_repo, "v1\n")
      write_repo_workflow!(workspace_root, source_repo)

      issue = fn identifier -> %Issue{identifier: identifier, project_slug: "project-a"} end
      settings = put_in(Config.settings!().workspace.repo_cache.max_age_ms, 0)

      assert {:ok, first_workspace} = Workspace.create_for_issue(issue.("PI-1"), nil, settings: settings)
      assert File.read!(Path.join(first_workspace, "README.md")) == "v1\n"

      commit_file!(source_repo, "README.md", "v2\n", "upstream v2")

      assert {:ok, second_workspace} = Workspace.create_for_issue(issue.("PI-2"), nil, settings: settings)
      assert File.read!(Path.join(second_workspace, "README.md")) == "v2\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "a fresh cache still fetches the issue branch pushed by another workspace" do
    test_root = temp_root!("issue-branch")
    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      init_repo!(source_repo, "base\n")
      write_repo_workflow!(workspace_root, source_repo)

      # Populate the cache (and its fresh marker) before the PR branch exists.
      other_issue = %Issue{identifier: "PI-OTHER", project_slug: "project-a"}
      assert {:ok, _workspace} = Workspace.create_for_issue(other_issue)

      System.cmd("git", ["-C", source_repo, "checkout", "-q", "-b", "symphony/PI-7"])
      commit_file!(source_repo, "feature.txt", "pr work\n", "pr work")
      System.cmd("git", ["-C", source_repo, "checkout", "-q", "main"])

      assert {:ok, workspace} = Workspace.create_for_issue(%Issue{identifier: "PI-7", project_slug: "project-a"})
      assert File.read!(Path.join(workspace, "feature.txt")) == "pr work\n"

      {upstream, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "--abbrev-ref", "@{upstream}"])
      assert String.trim(upstream) == "origin/symphony/PI-7"
    after
      File.rm_rf(test_root)
    end
  end

  test "a force-pushed issue branch is resumed inside the freshness window" do
    test_root = temp_root!("force-push")
    origin = Path.join(test_root, "origin.git")
    agent_repo = Path.join(test_root, "agent")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      init_bare_origin!(origin, agent_repo, "base\n")
      write_repo_workflow!(workspace_root, origin)

      issue = fn identifier -> %Issue{identifier: identifier, project_slug: "project-a"} end

      # Populate the cache (and its fresh marker) before the PR branch exists.
      assert {:ok, _workspace} = Workspace.create_for_issue(issue.("PI-OTHER"))

      assert :ok = force_push_issue_branch!(agent_repo, "symphony/PI-7", "v1.txt", "v1\n", "v1")

      assert {:ok, workspace} = Workspace.create_for_issue(issue.("PI-7"))
      assert File.read!(Path.join(workspace, "v1.txt")) == "v1\n"

      # The next start rebuilds the workspace while the cache is still inside its
      # freshness window, so only the targeted issue-branch fetch runs.
      assert :ok = Workspace.remove_issue_workspaces(issue.("PI-7"))
      assert :ok = force_push_issue_branch!(agent_repo, "symphony/PI-7", "v2.txt", "v2\n", "v2")

      assert {:ok, rewritten_workspace} = Workspace.create_for_issue(issue.("PI-7"))
      assert File.read!(Path.join(rewritten_workspace, "v2.txt")) == "v2\n"
      refute File.exists?(Path.join(rewritten_workspace, "v1.txt"))

      {upstream, 0} =
        System.cmd("git", ["-C", rewritten_workspace, "rev-parse", "--abbrev-ref", "@{upstream}"])

      assert String.trim(upstream) == "origin/symphony/PI-7"
    after
      File.rm_rf(test_root)
    end
  end

  test "a fresh start makes exactly one remote git operation" do
    test_root = temp_root!("one-remote-op")
    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")
    git_log = Path.join(test_root, "git-invocations.log")

    try do
      init_repo!(source_repo, "base\n")
      write_repo_workflow!(workspace_root, source_repo)

      # Populate the cache before the issue branch exists.
      assert {:ok, _workspace} =
               Workspace.create_for_issue(%Issue{identifier: "PI-OTHER", project_slug: "project-a"})

      System.cmd("git", ["-C", source_repo, "checkout", "-q", "-b", "symphony/PI-8"])
      commit_file!(source_repo, "feature.txt", "pr work\n", "pr work")
      System.cmd("git", ["-C", source_repo, "checkout", "-q", "main"])

      old_git_trace = System.get_env("GIT_TRACE")
      System.put_env("GIT_TRACE", git_log)

      try do
        assert {:ok, workspace} =
                 Workspace.create_for_issue(%Issue{identifier: "PI-8", project_slug: "project-a"})

        assert File.read!(Path.join(workspace, "feature.txt")) == "pr work\n"
      after
        if old_git_trace,
          do: System.put_env("GIT_TRACE", old_git_trace),
          else: System.delete_env("GIT_TRACE")
      end

      invocations = git_log |> File.read!() |> String.split("\n", trim: true)
      remote_operations = Enum.filter(invocations, &remote_git_operation?/1)

      assert length(remote_operations) == 1
      [operation] = remote_operations
      assert operation =~ "fetch"
      assert operation =~ "+refs/heads/symphony/PI-8:refs/remotes/origin/symphony/PI-8"
      refute Enum.any?(invocations, &String.contains?(&1, "ls-remote"))
      refute Enum.any?(invocations, &String.contains?(&1, "set-head"))
    after
      File.rm_rf(test_root)
    end
  end

  test "a fresh start aborts and leaves the ref alone when the issue branch fetch fails" do
    test_root = temp_root!("fresh-fetch-failure")
    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      init_repo!(source_repo, "base\n")
      write_repo_workflow!(workspace_root, source_repo)

      issue = fn identifier -> %Issue{identifier: identifier, project_slug: "project-a"} end

      assert {:ok, _workspace} = Workspace.create_for_issue(issue.("PI-OTHER"))

      System.cmd("git", ["-C", source_repo, "checkout", "-q", "-b", "symphony/PI-9"])
      commit_file!(source_repo, "feature.txt", "pr work\n", "pr work")
      System.cmd("git", ["-C", source_repo, "checkout", "-q", "main"])

      assert {:ok, workspace} = Workspace.create_for_issue(issue.("PI-9"))
      assert File.read!(Path.join(workspace, "feature.txt")) == "pr work\n"

      assert :ok = Workspace.remove_issue_workspaces(issue.("PI-9"))

      cache_repo = cache_repo_for(issue.("PI-9"))
      {old_ref, 0} = System.cmd("git", ["-C", cache_repo, "rev-parse", "refs/remotes/origin/symphony/PI-9"])
      missing_origin = Path.join(test_root, "missing-origin.git")
      System.cmd("git", ["-C", cache_repo, "remote", "set-url", "origin", missing_origin])

      assert {:error, {:workspace_repo_cache_failed, _display, status, output}} =
               Workspace.create_for_issue(issue.("PI-9"))

      refute status == 0
      assert output =~ "missing-origin"

      {new_ref, 0} = System.cmd("git", ["-C", cache_repo, "rev-parse", "refs/remotes/origin/symphony/PI-9"])
      assert new_ref == old_ref
    after
      File.rm_rf(test_root)
    end
  end

  test "a fresh start drops a local issue branch ref when the remote branch was deleted" do
    test_root = temp_root!("deleted-issue-branch")
    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      init_repo!(source_repo, "base\n")
      write_repo_workflow!(workspace_root, source_repo)

      issue = fn identifier -> %Issue{identifier: identifier, project_slug: "project-a"} end

      assert {:ok, _workspace} = Workspace.create_for_issue(issue.("PI-OTHER"))

      System.cmd("git", ["-C", source_repo, "checkout", "-q", "-b", "symphony/PI-10"])
      commit_file!(source_repo, "feature.txt", "pr work\n", "pr work")
      System.cmd("git", ["-C", source_repo, "checkout", "-q", "main"])

      assert {:ok, workspace} = Workspace.create_for_issue(issue.("PI-10"))
      assert File.read!(Path.join(workspace, "feature.txt")) == "pr work\n"

      assert :ok = Workspace.remove_issue_workspaces(issue.("PI-10"))
      System.cmd("git", ["-C", source_repo, "branch", "-q", "-D", "symphony/PI-10"])

      assert {:ok, recreated_workspace} = Workspace.create_for_issue(issue.("PI-10"))
      refute File.exists?(Path.join(recreated_workspace, "feature.txt"))

      cache_repo = cache_repo_for(issue.("PI-10"))

      assert {_output, 1} =
               System.cmd(
                 "git",
                 ["-C", cache_repo, "show-ref", "--verify", "--quiet", "refs/remotes/origin/symphony/PI-10"],
                 stderr_to_stdout: true
               )
    after
      File.rm_rf(test_root)
    end
  end

  test "concurrent workspace starts for one repo fetch only once" do
    test_root = temp_root!("coalesced")
    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      init_repo!(source_repo, "coalesced\n")
      write_repo_workflow!(workspace_root, source_repo)
      settings = Config.settings!()

      PrometheusMetrics.reset_repo_cache_metrics()

      results =
        ["PI-1", "PI-2"]
        |> Enum.map(fn identifier ->
          Task.async(fn ->
            Workspace.create_for_issue(
              %Issue{identifier: identifier, project_slug: "project-a"},
              nil,
              settings: settings
            )
          end)
        end)
        |> Task.await_many(60_000)

      assert Enum.all?(results, &match?({:ok, _workspace}, &1))

      body = PrometheusMetrics.render(%{})
      repo = source_repo

      assert body =~ ~s(symphony_repo_cache_fetches_total{repo="#{repo}",reason="first_clone"} 1)
      assert body =~ ~s(symphony_repo_cache_skipped_total{repo="#{repo}"} 1)
    after
      PrometheusMetrics.reset_repo_cache_metrics()
      File.rm_rf(test_root)
    end
  end

  test "prometheus metrics count repo cache fetches and skips by repo and reason" do
    PrometheusMetrics.reset_repo_cache_metrics()
    on_exit(&PrometheusMetrics.reset_repo_cache_metrics/0)

    assert :ok = PrometheusMetrics.record_repo_cache_fetch("/repos/a", :stale)
    assert :ok = PrometheusMetrics.record_repo_cache_fetch("/repos/a", :stale)
    assert :ok = PrometheusMetrics.record_repo_cache_fetch("/repos/a", :refresher)
    assert :ok = PrometheusMetrics.record_repo_cache_fetch("owner/repo", :first_clone)
    assert :ok = PrometheusMetrics.record_repo_cache_skip("/repos/a")
    assert :ok = PrometheusMetrics.record_repo_cache_skip("/repos/a")

    body = PrometheusMetrics.render(%{})

    assert body =~
             "# HELP symphony_repo_cache_fetches_total Repo cache fetches from the remote, by repo and reason."

    assert body =~ "# TYPE symphony_repo_cache_fetches_total counter"
    assert body =~ ~s(symphony_repo_cache_fetches_total{repo="/repos/a",reason="stale"} 2)
    assert body =~ ~s(symphony_repo_cache_fetches_total{repo="/repos/a",reason="refresher"} 1)
    assert body =~ ~s(symphony_repo_cache_fetches_total{repo="owner/repo",reason="first_clone"} 1)
    assert body =~ ~s(symphony_repo_cache_skipped_total{repo="/repos/a"} 2)

    PrometheusMetrics.reset_repo_cache_metrics()
    refute PrometheusMetrics.render(%{}) =~ "symphony_repo_cache_fetches_total{"
  end

  test "refresher fetches every configured repo locally and updates each marker" do
    test_root = temp_root!("refresher")
    repo_a = Path.join(test_root, "repo-a")
    repo_b = Path.join(test_root, "repo-b")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      init_repo!(repo_a, "a v1\n")
      init_repo!(repo_b, "b v1\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: nil,
        tracker_projects: [
          %{slug: "project-a", repo: repo_a},
          %{slug: "project-b", repo: repo_b}
        ],
        workspace_root: workspace_root
      )

      # 0 keeps the second pass stale regardless of how fast the test runs.
      settings = put_in(Config.settings!().workspace.repo_cache.max_age_ms, 0)
      name = :"repo_cache_refresher_#{System.unique_integer([:positive])}"
      previous_enabled = Application.get_env(:symphony_elixir, :repo_cache_refresher_enabled)

      Application.put_env(:symphony_elixir, :repo_cache_refresher_enabled, true)

      on_exit(fn ->
        Application.put_env(:symphony_elixir, :repo_cache_refresher_enabled, previous_enabled)
      end)

      start_supervised!({RepoCacheRefresher, name: name, settings_fun: fn -> {:ok, settings} end})

      send(Process.whereis(name), :refresh)
      :sys.get_state(name)

      markers =
        for route <- Config.linear_project_routes(settings) do
          marker = fetcher_marker_for(route, settings)
          assert File.regular?(marker)
          {route, marker}
        end

      assert length(markers) == 2

      commit_file!(repo_a, "README.md", "a v2\n", "a v2")

      assert :ok = RepoCacheRefresher.refresh_now(name)
      :sys.get_state(name)

      [{route_a, marker_a} | _rest] = markers
      cache_a = Path.dirname(Path.dirname(marker_a))
      assert cache_a == repo_cache_path(route_a, settings)

      {log, 0} = System.cmd("git", ["-C", cache_a, "log", "-1", "--format=%s", "origin/main"])
      assert String.trim(log) == "a v2"

      assert_marker_recent(marker_a)
    after
      File.rm_rf(test_root)
    end
  end

  test "refresher logs repo errors and keeps running" do
    test_root = temp_root!("refresher-errors")
    repo = Path.join(test_root, "repo")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      init_repo!(repo, "errors\n")
      write_repo_workflow!(workspace_root, repo)

      settings = Config.settings!()

      sync_funs = [
        fn _route, _settings -> {:error, :boom} end,
        fn _route, _settings -> raise "kaboom" end,
        fn _route, _settings -> throw(:thrown) end
      ]

      for {sync_fun, index} <- Enum.with_index(sync_funs) do
        name = :"repo_cache_refresher_errors_#{index}_#{System.unique_integer([:positive])}"

        start_supervised!(
          {RepoCacheRefresher, name: name, settings_fun: fn -> {:ok, settings} end, sync_fun: sync_fun},
          id: {:refresher_errors, index}
        )

        log =
          capture_log(fn ->
            send(Process.whereis(name), :refresh)
            :sys.get_state(name)
          end)

        assert log =~ "Repo cache refresh"
        assert log =~ repo
        assert Process.alive?(Process.whereis(name))
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "refresher skips everything when the interval is 0 and survives bad settings" do
    test_root = temp_root!("refresher-off")
    repo = Path.join(test_root, "repo")
    workspace_root = Path.join(test_root, "workspaces")

    try do
      init_repo!(repo, "off\n")
      write_repo_workflow!(workspace_root, repo)

      settings = put_in(Config.settings!().workspace.repo_cache.refresh_interval_ms, 0)
      test_pid = self()
      name = :"repo_cache_refresher_off_#{System.unique_integer([:positive])}"
      synced = fn _route, _settings -> send(test_pid, :synced) end

      start_refresher!(name, fn -> {:ok, settings} end, synced)

      assert :ok = RepoCacheRefresher.refresh_now(name)
      :sys.get_state(name)
      refute_received :synced

      bad_settings_name = :"repo_cache_refresher_bad_settings_#{System.unique_integer([:positive])}"

      noop = fn _route, _settings -> :ok end
      start_refresher!(bad_settings_name, fn -> {:error, :no_settings} end, noop, id: :refresher_bad_settings)

      log =
        capture_log(fn ->
          send(Process.whereis(bad_settings_name), :refresh)
          :sys.get_state(bad_settings_name)
        end)

      assert log =~ "Repo cache refresh skipped"

      raising_name = :"repo_cache_refresher_raising_settings_#{System.unique_integer([:positive])}"

      start_refresher!(raising_name, fn -> raise "settings blew up" end, noop, id: :refresher_raising_settings)

      log =
        capture_log(fn ->
          send(Process.whereis(raising_name), :refresh)
          :sys.get_state(raising_name)
        end)

      assert log =~ "settings blew up"
    after
      File.rm_rf(test_root)
    end
  end

  test "repo cache lock serializes holders and drops a waiter that dies" do
    key = {:lock_test, System.unique_integer([:positive])}
    parent = self()

    holder =
      spawn(fn ->
        RepoCacheLock.with_lock(key, fn ->
          send(parent, :held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :held, 1_000

    waiter = spawn(fn -> RepoCacheLock.with_lock(key, fn -> send(parent, :waiter_ran) end) end)
    waiter_monitor = Process.monitor(waiter)
    Process.sleep(50)

    Process.exit(waiter, :kill)
    assert_receive {:DOWN, ^waiter_monitor, :process, ^waiter, :killed}, 1_000
    Process.sleep(50)

    send(holder, :release)
    refute_received :waiter_ran

    assert :locked = RepoCacheLock.with_lock(key, fn -> :locked end)
  end

  test "repo cache lock queues multiple waiters under one holder" do
    key = {:lock_queue, System.unique_integer([:positive])}
    parent = self()

    holder =
      spawn(fn ->
        RepoCacheLock.with_lock(key, fn ->
          send(parent, :held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :held, 1_000

    waiters =
      for index <- 1..2 do
        Task.async(fn ->
          RepoCacheLock.with_lock(key, fn ->
            send(parent, {:waiter_ran, index})
            Process.sleep(50)
            index
          end)
        end)
      end

    Process.sleep(50)
    send(holder, :release)

    assert_receive {:waiter_ran, 1}, 1_000
    assert_receive {:waiter_ran, 2}, 1_000
    assert Enum.sort(Task.await_many(waiters, 1_000)) == [1, 2]
  end

  test "repo cache lock releases the lock when its holder dies" do
    key = {:lock_holder_death, System.unique_integer([:positive])}
    parent = self()

    holder =
      spawn(fn ->
        RepoCacheLock.with_lock(key, fn ->
          send(parent, :held)

          receive do
            :never -> :ok
          end
        end)
      end)

    assert_receive :held, 1_000

    waiter =
      Task.async(fn ->
        RepoCacheLock.with_lock(key, fn ->
          send(parent, :waiter_ran)
          :ok
        end)
      end)

    Process.sleep(50)
    Process.exit(holder, :kill)

    assert_receive :waiter_ran, 1_000
    assert :ok = Task.await(waiter, 1_000)
  end

  test "repo cache lock demonitors the holder on release" do
    key = {:lock_demonitor, System.unique_integer([:positive])}
    server = Process.whereis(RepoCacheLock)
    assert is_pid(server)

    assert :ok = RepoCacheLock.with_lock(key, fn -> :ok end)

    {:monitors, monitors} = Process.info(server, :monitors)
    refute Enum.any?(monitors, fn {pid, _ref} -> pid == self() end)
  end

  test "repo cache lock ignores a stale release after the lock server restarts" do
    key = {:lock_stale_release, System.unique_integer([:positive])}
    parent = self()

    on_exit(fn ->
      if is_nil(Process.whereis(RepoCacheLock)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, RepoCacheLock)
      end
    end)

    old_holder =
      spawn(fn ->
        RepoCacheLock.with_lock(key, fn ->
          send(parent, :old_holder_acquired)

          receive do
            :release_old_holder -> :ok
          end
        end)
      end)

    assert_receive :old_holder_acquired, 1_000

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, RepoCacheLock)
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, RepoCacheLock)

    new_holder =
      spawn(fn ->
        RepoCacheLock.with_lock(key, fn ->
          send(parent, :new_holder_acquired)

          receive do
            :release_new_holder -> :ok
          end
        end)
      end)

    assert_receive :new_holder_acquired, 1_000

    # The old holder still finishes its `with_lock` after the restart. Its stale
    # release must not free the new holder's lock.
    send(old_holder, :release_old_holder)
    Process.sleep(50)

    third = Task.async(fn -> RepoCacheLock.with_lock(key, fn -> send(parent, :third_acquired) end) end)
    refute_receive :third_acquired, 200

    send(new_holder, :release_new_holder)
    assert_receive :third_acquired, 1_000
    assert :third_acquired = Task.await(third, 1_000)
  end

  test "refresher uses a fixed-rate schedule and starts immediately after an overrun" do
    test_root = temp_root!("refresher-fixed-rate")
    repo = Path.join(test_root, "repo")
    workspace_root = Path.join(test_root, "workspaces")
    parent = self()

    try do
      init_repo!(repo, "fixed rate\n")
      write_repo_workflow!(workspace_root, repo)

      settings = put_in(Config.settings!().workspace.repo_cache.refresh_interval_ms, 500)
      name = :"repo_cache_refresher_fixed_rate_#{System.unique_integer([:positive])}"

      sync_fun = fn _route, _settings ->
        send(parent, {:synced, System.monotonic_time(:millisecond)})
        Process.sleep(300)
        :ok
      end

      start_refresher!(name, fn -> {:ok, settings} end, sync_fun)

      send(Process.whereis(name), :refresh)
      assert_receive {:synced, first_started_at}, 2_000

      # Wait for the overrunning pass to finish, then inspect the next timer. A
      # fixed-rate schedule leaves ~200ms of the 500ms interval; scheduling from
      # the end of the pass would leave the full 500ms.
      %{timer_ref: timer_ref} = :sys.get_state(name)
      remaining_ms = Process.read_timer(timer_ref)
      assert is_integer(remaining_ms)
      assert remaining_ms < 400

      assert_receive {:synced, second_started_at}, 1_000
      assert second_started_at - first_started_at < 700
    after
      File.rm_rf(test_root)
    end
  end

  test "schema validates repo cache settings and defaults to a one-minute window" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.workspace.repo_cache.max_age_ms == 60_000
    assert settings.workspace.repo_cache.refresh_interval_ms == 30_000

    assert {:ok, settings} =
             Schema.parse(%{
               "workspace" => %{"repo_cache" => %{"max_age_ms" => 0, "refresh_interval_ms" => 0}}
             })

    assert settings.workspace.repo_cache.max_age_ms == 0
    assert settings.workspace.repo_cache.refresh_interval_ms == 0

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "workspace" => %{"repo_cache" => %{"max_age_ms" => -1, "refresh_interval_ms" => -1}}
             })

    assert message =~ "max_age_ms"
    assert message =~ "refresh_interval_ms"
  end

  defp init_bare_origin!(origin, agent_repo, readme_contents) do
    System.cmd("git", ["init", "--bare", "-q", "-b", "main", origin])
    File.mkdir_p!(agent_repo)
    File.write!(Path.join(agent_repo, "README.md"), readme_contents)
    System.cmd("git", ["-C", agent_repo, "init", "-q", "-b", "main"])
    System.cmd("git", ["-C", agent_repo, "add", "README.md"])
    System.cmd("git", ["-C", agent_repo, "commit", "-q", "-m", "initial"])
    System.cmd("git", ["-C", agent_repo, "remote", "add", "origin", origin])
    System.cmd("git", ["-C", agent_repo, "push", "-q", "-u", "origin", "main"])
    :ok
  end

  defp force_push_issue_branch!(repo, branch, relative_path, contents, message) do
    System.cmd("git", ["-C", repo, "checkout", "-q", "-B", branch, "main"])
    File.write!(Path.join(repo, relative_path), contents)
    System.cmd("git", ["-C", repo, "add", "-A"])
    System.cmd("git", ["-C", repo, "commit", "-q", "-m", message])
    System.cmd("git", ["-C", repo, "push", "-q", "-f", "origin", branch])
    System.cmd("git", ["-C", repo, "checkout", "-q", "main"])
    :ok
  end

  defp remote_git_operation?(line) do
    (String.contains?(line, " fetch ") and String.contains?(line, " origin")) or
      String.contains?(line, "ls-remote") or
      String.contains?(line, "set-head")
  end

  defp start_refresher!(name, settings_fun, sync_fun, opts \\ []) do
    start_supervised!(
      {RepoCacheRefresher, name: name, settings_fun: settings_fun, sync_fun: sync_fun},
      id: Keyword.get(opts, :id, name)
    )
  end

  defp temp_root!(suffix) do
    Path.join(System.tmp_dir!(), "symphony-elixir-repo-cache-#{suffix}-#{System.unique_integer([:positive])}")
  end

  defp write_repo_workflow!(workspace_root, repo) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_projects: [%{slug: "project-a", repo: repo}],
      workspace_root: workspace_root
    )
  end

  defp init_repo!(path, readme_contents) do
    File.mkdir_p!(path)
    File.write!(Path.join(path, "README.md"), readme_contents)
    System.cmd("git", ["-C", path, "init", "-b", "main"])
    System.cmd("git", ["-C", path, "add", "README.md"])
    System.cmd("git", ["-C", path, "commit", "-q", "-m", "initial"])
  end

  defp commit_file!(repo, relative_path, contents, message) do
    File.write!(Path.join(repo, relative_path), contents)
    System.cmd("git", ["-C", repo, "add", relative_path])
    System.cmd("git", ["-C", repo, "commit", "-q", "-m", message])
  end

  defp cache_repo_for(issue) do
    repo_source = Config.project_repo_source_for_issue(issue)
    Path.join([Config.workspace_root_for_issue(issue), ".symphony-cache", repo_source.cache_key])
  end

  defp fetcher_marker_for(route, settings) do
    Path.join([repo_cache_path(route, settings), ".git", "symphony-fetched-at"])
  end

  defp repo_cache_path(route, settings) do
    repo_source = Config.repo_source(route.repo)
    Path.join([Config.workspace_root_for_route(route, settings), ".symphony-cache", repo_source.cache_key])
  end

  defp assert_marker_recent(marker) do
    {:ok, contents} = File.read(marker)

    fetched_at =
      case contents |> String.trim() |> Integer.parse() do
        {seconds, ""} -> seconds
      end

    now = System.system_time(:second)
    assert fetched_at <= now
    assert now - fetched_at < 300
  end
end
