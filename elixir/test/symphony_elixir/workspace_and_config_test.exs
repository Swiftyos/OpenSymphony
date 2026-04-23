defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.StringOrMap
  alias SymphonyElixir.Linear.Client

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace routes issues into project-specific repos and roots" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-project-routing-#{System.unique_integer([:positive])}"
      )

    try do
      product_repo = Path.join(test_root, "product-source")
      agent_repo = Path.join(test_root, "agent-source")
      default_workspace_root = Path.join(test_root, "workspaces")
      product_workspace_root = Path.join(test_root, "product-workspaces")

      init_repo!(product_repo, "project a\n")
      init_repo!(agent_repo, "project b\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: nil,
        tracker_projects: [
          %{
            slug: "project-a",
            repo: product_repo,
            workspace_root: product_workspace_root
          },
          %{
            slug: "project-b",
            repo: agent_repo
          }
        ],
        workspace_root: default_workspace_root
      )

      product_issue = %Issue{identifier: "PI-1", project_slug: "project-a"}
      agent_issue = %Issue{identifier: "AP-1", project_slug: "project-b"}

      assert {:ok, product_workspace} = Workspace.create_for_issue(product_issue)
      assert {:ok, agent_workspace} = Workspace.create_for_issue(agent_issue)

      assert {:ok, expected_product_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(product_workspace_root, "PI-1"))

      assert {:ok, expected_agent_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([default_workspace_root, "project-b", "AP-1"]))

      assert product_workspace == expected_product_workspace
      assert agent_workspace == expected_agent_workspace

      assert File.read!(Path.join(product_workspace, "README.md")) == "project a\n"
      assert File.read!(Path.join(agent_workspace, "README.md")) == "project b\n"

      assert Config.workspace_root_for_issue(product_issue) == product_workspace_root
      assert Config.workspace_root_for_issue(agent_issue) == Path.join(default_workspace_root, "project-b")
      assert Config.project_repo_for_issue(product_issue) == product_repo
      assert Config.project_repo_for_issue(agent_issue) == agent_repo

      assert {:ok, ^expected_product_workspace} = Config.validate_workspace_path(product_workspace)
      assert {:ok, ^expected_agent_workspace} = Config.validate_workspace_path(agent_workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace bootstraps issue worktrees from a cached repo checkout" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-cache-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      init_repo!(source_repo, "cached bootstrap\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: nil,
        tracker_projects: [
          %{
            slug: "project-a",
            repo: source_repo
          }
        ],
        workspace_root: workspace_root
      )

      issue = %Issue{identifier: "PI-1", project_slug: "project-a"}

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "README.md")) == "cached bootstrap\n"
      assert File.regular?(Path.join(workspace, ".git"))

      {branch_name, 0} = System.cmd("git", ["-C", workspace, "branch", "--show-current"])
      assert String.trim(branch_name) == "symphony/PI-1"

      repo_source = Config.project_repo_source_for_issue(issue)
      cache_repo = Path.join(Config.workspace_root_for_issue(issue), ".symphony-cache/#{repo_source.cache_key}")

      assert File.dir?(cache_repo)

      {worktree_list, 0} = System.cmd("git", ["-C", cache_repo, "worktree", "list", "--porcelain"])
      assert worktree_list =~ workspace

      assert :ok = Workspace.remove_issue_workspaces(issue)
      refute File.exists?(workspace)

      {worktree_list_after_remove, 0} = System.cmd("git", ["-C", cache_repo, "worktree", "list", "--porcelain"])
      refute worktree_list_after_remove =~ workspace
    after
      File.rm_rf(test_root)
    end
  end

  test "preflight reuses an existing cached clone and refreshes it" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-cache-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      init_repo!(source_repo, "cached bootstrap\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: nil,
        tracker_projects: [
          %{
            slug: "project-a",
            repo: source_repo
          }
        ],
        workspace_root: workspace_root
      )

      issue = %Issue{identifier: "PI-1", project_slug: "project-a"}

      assert {:ok, _workspace} = Workspace.create_for_issue(issue)

      repo_source = Config.project_repo_source_for_issue(issue)
      cache_repo = Path.join(Config.workspace_root_for_issue(issue), ".symphony-cache/#{repo_source.cache_key}")
      sentinel = Path.join(cache_repo, "cache-sentinel.txt")

      File.write!(sentinel, "keep me\n")

      File.write!(Path.join(source_repo, "README.md"), "updated upstream\n")
      System.cmd("git", ["-C", source_repo, "add", "README.md"])
      System.cmd("git", ["-C", source_repo, "commit", "-m", "update upstream"])

      assert :ok = Workspace.preflight_repo_setup!(Config.settings!())
      assert File.read!(sentinel) == "keep me\n"
      assert File.read!(Path.join(cache_repo, "README.md")) == "updated upstream\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "project" => %{
        "id" => "project-1",
        "slugId" => "project-a",
        "name" => "Project A"
      },
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.project_id == "project-1"
    assert issue.project_slug == "project-a"
    assert issue.project_name == "Project A"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "linear client preserves grouped label namespace for routing labels" do
    raw_issue = %{
      "id" => "issue-2",
      "identifier" => "MT-2",
      "title" => "Grouped labels",
      "description" => "Needs grouped labels",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "project" => %{
        "id" => "project-1",
        "slugId" => "project-a",
        "name" => "Project A"
      },
      "branchName" => "mt-2",
      "url" => "https://example.org/issues/MT-2",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{
        "nodes" => [
          %{"name" => "Claude"},
          %{"name" => "Low", "parent" => %{"name" => "Thinking"}}
        ]
      },
      "inverseRelations" => %{"nodes" => []},
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.labels == ["claude", "thinking/low"]
    assert SymphonyElixir.AgentRoute.resolve(issue).backend == "claude"
    assert SymphonyElixir.AgentRoute.resolve(issue).effort == "low"
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query, %{ids: ^first_batch_ids, first: 50, relationFirst: 50}}
    assert query =~ "SymphonyLinearIssuesById"

    assert_receive {:fetch_issue_states_page, ^query, %{ids: ^second_batch_ids, first: 5, relationFirst: 50}}
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:symphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:symphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      opencode_command: nil,
      opencode_agent: nil,
      opencode_model: nil,
      opencode_turn_timeout_ms: nil,
      opencode_read_timeout_ms: nil,
      opencode_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.max_concurrent_agents == 10
    assert config.agent.backend == "opencode"
    assert config.agent.default_effort == nil
    assert config.codex.command == "codex app-server"
    assert config.codex.thread_sandbox == "workspace-write"
    assert config.codex.turn_timeout_ms == 3_600_000
    assert config.codex.read_timeout_ms == 5_000
    assert config.codex.stall_timeout_ms == 300_000
    assert config.opencode.command == "opencode serve --hostname 127.0.0.1 --port 0"
    assert config.opencode.agent == "build"
    assert config.opencode.model == nil
    assert config.opencode.turn_timeout_ms == 3_600_000
    assert config.opencode.read_timeout_ms == 5_000
    assert config.opencode.stall_timeout_ms == 300_000
    assert config.claude.command == "claude"
    assert config.claude.model == nil
    assert config.claude.permission_mode == "bypassPermissions"
    assert config.claude.turn_timeout_ms == 3_600_000
    assert config.claude.read_timeout_ms == 5_000
    assert config.claude.stall_timeout_ms == 300_000
    assert Config.agent_backend() == "opencode"
    assert Config.agent_stall_timeout_ms() == 300_000

    assert {:ok, canonical_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert {:ok, codex_runtime_settings} = Config.codex_runtime_settings()

    assert codex_runtime_settings == %{
             approval_policy: %{
               "reject" => %{
                 "sandbox_approval" => true,
                 "rules" => true,
                 "mcp_elicitations" => true
               }
             },
             thread_sandbox: "workspace-write",
             turn_sandbox_policy: %{
               "type" => "workspaceWrite",
               "writableRoots" => [canonical_workspace_root],
               "readOnlyAccess" => %{"type" => "fullAccess"},
               "networkAccess" => false,
               "excludeTmpdirEnvVar" => false,
               "excludeSlashTmp" => false
             }
           }

    assert {:ok, runtime_settings} = Config.opencode_runtime_settings()

    assert runtime_settings == %{
             command: "opencode serve --hostname 127.0.0.1 --port 0",
             agent: "build",
             model: nil,
             variant: nil,
             turn_timeout_ms: 3_600_000,
             read_timeout_ms: 5_000,
             stall_timeout_ms: 300_000
           }

    assert {:ok, claude_runtime_settings} = Config.claude_runtime_settings()

    assert claude_runtime_settings == %{
             command: "claude",
             model: nil,
             effort: nil,
             permission_mode: "bypassPermissions",
             turn_timeout_ms: 3_600_000,
             read_timeout_ms: 5_000,
             stall_timeout_ms: 300_000
           }

    write_workflow_file!(Workflow.workflow_file_path(),
      opencode_command: "opencode serve --hostname 127.0.0.1 --port 4200",
      opencode_agent: "review",
      opencode_model: "openai/gpt-5.4"
    )

    config = Config.settings!()
    assert config.opencode.command == "opencode serve --hostname 127.0.0.1 --port 4200"
    assert config.opencode.agent == "review"
    assert config.opencode.model == "openai/gpt-5.4"

    write_workflow_file!(Workflow.workflow_file_path(),
      claude_command: "claude --debug",
      claude_model: "sonnet",
      claude_permission_mode: "dontAsk"
    )

    config = Config.settings!()
    assert config.claude.command == "claude --debug"
    assert config.claude.model == "sonnet"
    assert config.claude.permission_mode == "dontAsk"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), opencode_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "opencode.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), opencode_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "opencode.read_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), opencode_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "opencode.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), opencode_model: "gpt-5.4")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "opencode.model"

    write_workflow_file!(Workflow.workflow_file_path(), claude_permission_mode: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "claude.permission_mode"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    opencode_bin = Path.join(["~", "bin", "opencode"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      opencode_command: "#{opencode_bin} serve --hostname 127.0.0.1 --port 0"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.opencode.command == "#{opencode_bin} serve --hostname 127.0.0.1 --port 0"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "OpenCode v1 is local-only"
    assert message =~ "worker.max_concurrent_agents_per_host"
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]
  end

  test "schema parse resolves env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"
    missing_openrouter_env = "SYMP_MISSING_OPENROUTER_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_missing_openrouter_env = System.get_env(missing_openrouter_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    previous_openrouter_api_key = System.get_env("OPENROUTER_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.delete_env(missing_openrouter_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")
    System.put_env("OPENROUTER_API_KEY", "fallback-openrouter-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env(missing_openrouter_env, previous_missing_openrouter_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      restore_env("OPENROUTER_API_KEY", previous_openrouter_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}"},
               providers: %{openrouter_api_key: "$#{missing_openrouter_env}"},
               workspace: %{root: "$#{missing_workspace_env}"}
             })

    assert settings.tracker.api_key == nil
    assert settings.providers.openrouter_api_key == "fallback-openrouter-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{missing_secret_env}"},
               providers: %{openrouter_api_key: "$#{empty_secret_env}"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.providers.openrouter_api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "schema parse accepts codex config and infers codex backend" do
    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               codex: %{command: "codex app-server --model gpt-5.3-codex"}
             })

    assert settings.agent.backend == "codex"
    assert settings.codex.command == "codex app-server --model gpt-5.3-codex"
  end

  test "schema parse accepts claude config and infers claude backend" do
    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               claude: %{command: "claude --debug", permission_mode: "dontAsk", model: "sonnet"}
             })

    assert settings.agent.backend == "claude"
    assert settings.claude.command == "claude --debug"
    assert settings.claude.permission_mode == "dontAsk"
    assert settings.claude.model == "sonnet"
  end

  test "schema parse accepts explicit backend selection" do
    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               agent: %{backend: "opencode"},
               codex: %{command: "codex app-server"},
               opencode: %{command: "opencode serve --hostname 127.0.0.1 --port 4200", agent: "review"}
             })

    assert settings.agent.backend == "opencode"
    assert settings.opencode.command == "opencode serve --hostname 127.0.0.1 --port 4200"

    assert {:ok, claude_settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               agent: %{backend: "claude"},
               codex: %{command: "codex app-server"},
               claude: %{command: "claude", permission_mode: "bypassPermissions"}
             })

    assert claude_settings.agent.backend == "claude"
    assert claude_settings.claude.command == "claude"
  end

  test "schema parse accepts valid default effort" do
    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               agent: %{backend: "codex", default_effort: " MAX "}
             })

    assert settings.agent.backend == "codex"
    assert settings.agent.default_effort == "max"
  end

  test "schema parse rejects invalid default effort" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               agent: %{backend: "codex", default_effort: "turbo"}
             })

    assert message =~ "agent.default_effort"
    assert message =~ "low, medium, high, xhigh, max"
  end

  test "schema parse accepts telemetry config and validates protocol" do
    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               telemetry: %{
                 enabled: true,
                 otlp_endpoint: "http://localhost:11338",
                 otlp_protocol: "grpc",
                 include_traces: true,
                 include_metrics: true,
                 include_logs: true,
                 resource_attributes: %{"environment" => "test"}
               }
             })

    assert settings.telemetry.enabled == true
    assert settings.telemetry.otlp_endpoint == "http://localhost:11338"
    assert settings.telemetry.otlp_protocol == "grpc"
    assert settings.telemetry.include_traces == true
    assert settings.telemetry.include_metrics == true
    assert settings.telemetry.include_logs == true
    assert settings.telemetry.resource_attributes == %{"environment" => "test"}

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               telemetry: %{otlp_protocol: "websocket"}
             })

    assert message =~ "telemetry.otlp_protocol"
  end

  test "config telemetry_issue_resource_attributes builds OTEL resource attributes string" do
    write_workflow_file!(Workflow.workflow_file_path(),
      instance_name: "test-instance",
      telemetry_enabled: true,
      telemetry_resource_attributes: %{"environment" => "test"}
    )

    issue = %{id: "issue-123", identifier: "MT-123"}
    attrs = Config.telemetry_issue_resource_attributes(issue)

    assert attrs =~ "linear.issue.id=issue-123"
    assert attrs =~ "linear.issue.identifier=MT-123"
    assert attrs =~ "symphony.instance=test-instance"
    assert attrs =~ "environment=test"

    account_attrs =
      Config.telemetry_issue_resource_attributes(issue, "codex", %{
        id: "primary",
        email: "primary@example.com",
        backend: "codex",
        state: "healthy",
        credential_kind: "codex_home"
      })

    assert account_attrs =~ "symphony.account.id=primary"
    assert account_attrs =~ "symphony.account.email=primary%40example.com"
    assert account_attrs =~ "symphony.account.backend=codex"
    assert account_attrs =~ "symphony.account.state=healthy"
    assert account_attrs =~ "symphony.account.credential_kind=codex_home"
  end

  test "config accepts accounts defaults, budgets, and path expansion" do
    workflow_dir = Path.dirname(Workflow.workflow_file_path())

    write_workflow_file!(Workflow.workflow_file_path(),
      accounts_enabled: true,
      accounts_store_root: "managed-accounts",
      accounts_allow_host_auth_fallback: true,
      accounts_max_concurrent_sessions_per_account: 2,
      accounts_exhausted_cooldown_ms: 123_000,
      accounts_daily_token_budget: 10_000,
      accounts_monthly_token_budget: 200_000
    )

    config = Config.settings!()

    assert config.accounts.enabled == true
    assert config.accounts.store_root == Path.expand("managed-accounts", workflow_dir)
    assert config.accounts.allow_host_auth_fallback == true
    assert config.accounts.rotation_strategy == "usage_aware_round_robin"
    assert config.accounts.max_concurrent_sessions_per_account == 2
    assert config.accounts.exhausted_cooldown_ms == 123_000
    assert config.accounts.daily_token_budget == 10_000
    assert config.accounts.monthly_token_budget == 200_000
  end

  test "config accepts common account boolean spellings" do
    assert {:ok, config} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "accounts" => %{
                 "enabled" => "YES",
                 "allow_host_auth_fallback" => "no"
               }
             })

    assert config.accounts.enabled == true
    assert config.accounts.allow_host_auth_fallback == false
  end

  test "schema parse infers backend from a lone provider block" do
    assert {:ok, opencode_settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               opencode: %{command: "opencode serve --hostname 127.0.0.1 --port 4200", agent: "review"}
             })

    assert opencode_settings.agent.backend == "opencode"

    assert {:ok, codex_settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               codex: %{command: "codex app-server --model gpt-5.4-codex"}
             })

    assert codex_settings.agent.backend == "codex"

    assert {:ok, claude_settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               claude: %{command: "claude", permission_mode: "bypassPermissions"}
             })

    assert claude_settings.agent.backend == "claude"
  end

  test "schema parse defaults to codex when backend selection is ambiguous or absent" do
    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"}
             })

    assert settings.agent.backend == "codex"

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               codex: %{command: "codex app-server"},
               opencode: %{command: "opencode serve --hostname 127.0.0.1 --port 0", agent: "build"}
             })

    assert settings.agent.backend == "codex"
  end

  test "schema parse rejects unsupported opencode sandbox and approval keys" do
    for key <- ["approval_policy", "thread_sandbox", "turn_sandbox_policy"] do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 tracker: %{kind: "memory"},
                 opencode: %{key => "legacy-value"}
               })

      assert message =~ "`opencode.#{key}` is no longer supported"
    end
  end

  test "config validation rejects local-only ssh worker settings only for opencode" do
    write_workflow_file!(Workflow.workflow_file_path(), worker_ssh_hosts: ["worker-01"])

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "OpenCode v1 is local-only"
    assert message =~ "worker.ssh_hosts"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "OpenCode v1 is local-only"
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "codex",
      worker_ssh_hosts: ["worker-01"],
      worker_max_concurrent_agents_per_host: 2
    )

    assert :ok = Config.validate!()
    assert Config.agent_backend() == "codex"
    assert Config.agent_stall_timeout_ms() == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "claude",
      worker_ssh_hosts: ["worker-02"],
      worker_max_concurrent_agents_per_host: 3,
      claude_stall_timeout_ms: 123_000
    )

    assert :ok = Config.validate!()
    assert Config.agent_backend() == "claude"
    assert Config.agent_stall_timeout_ms() == 123_000
  end

  test "config runtime helpers preserve existing behavior when default effort is unset" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "codex", default_effort: nil)

    assert Config.settings!().agent.default_effort == nil
    assert Config.codex_command() == "codex app-server"
    assert Config.codex_command("max") == "codex app-server -c model_reasoning_effort=xhigh"
    assert Config.codex_command("xhigh") == "codex app-server -c model_reasoning_effort=xhigh"
    assert Config.codex_command("high") == "codex app-server -c model_reasoning_effort=high"

    assert {:ok, opencode_runtime_settings} = Config.opencode_runtime_settings()
    assert opencode_runtime_settings.variant == nil

    assert {:ok, claude_runtime_settings} = Config.claude_runtime_settings()
    assert claude_runtime_settings.effort == nil
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as Symphony instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "symphony config parses top-level projects and resolves relative paths" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-global-config-#{System.unique_integer([:positive])}"
      )

    try do
      repo_root = Path.join(test_root, "repos/product")
      _workflow_path = Path.join(repo_root, "PRODUCT_WORKFLOW.md")
      config_path = Path.join(test_root, "symphony.yml")
      workspace_root = Path.join(test_root, "workspaces")
      project_workspace_root = Path.join(test_root, "project-workspaces")

      init_repo!(repo_root, "product repo\n")
      write_project_workflow_repo_file!(repo_root, "PRODUCT_WORKFLOW.md")

      write_symphony_config_file!(config_path,
        workspace_root: workspace_root,
        projects: [
          %{
            linear_project: "project-a",
            repo: "./repos/product",
            workflow: "./PRODUCT_WORKFLOW.md",
            workspace_root: "./project-workspaces",
            backend: "claude"
          }
        ]
      )

      SymphonyConfig.set_config_file_path(config_path)

      settings = Config.settings!()
      assert [%{slug: "project-a"} = route] = Config.linear_project_routes(settings)
      assert route.repo == repo_root
      assert route.workflow == "./PRODUCT_WORKFLOW.md"
      assert route.workspace_root == project_workspace_root
      assert route.backend == "claude"
    after
      File.rm_rf(test_root)
    end
  end

  test "symphony config parses instance name and server port" do
    config_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-instance-config-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(config_root)
      config_path = Path.join(config_root, "symphony.yml")
      project_workflow = Path.join(config_root, "PROJECT_WORKFLOW.md")

      write_project_workflow_file!(project_workflow)

      write_symphony_config_file!(config_path,
        instance_name: "Madrid Runner",
        server_port: 4101
      )

      SymphonyConfig.set_config_file_path(config_path)

      settings = Config.settings!()
      assert settings.instance.name == "Madrid Runner"
      assert settings.server.port == 4101
      assert Config.instance_name() == "Madrid Runner"
      assert Config.server_port() == 4101
    after
      File.rm_rf(config_root)
    end
  end

  test "config resolves GitHub repo slugs into cloneable repo sources" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-global-config-github-slug-#{System.unique_integer([:positive])}"
      )

    try do
      config_path = Path.join(test_root, "symphony.yml")

      File.mkdir_p!(test_root)

      write_symphony_config_file!(config_path,
        tracker_kind: "memory",
        projects: [
          %{
            linear_project: "project-a",
            repo: "openai/symphony",
            workflow: "WORKFLOW.md"
          }
        ]
      )

      SymphonyConfig.set_config_file_path(config_path)

      issue = %Issue{identifier: "PI-22", project_slug: "project-a"}

      assert :ok = Config.validate!()

      assert %{
               kind: :github_slug,
               clone_url: "https://github.com/openai/symphony.git",
               display: "openai/symphony"
             } = Config.project_repo_source_for_issue(issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "config validate rejects duplicate symphony project slugs" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-global-config-dupes-#{System.unique_integer([:positive])}"
      )

    try do
      workflow_path = Path.join(test_root, "PROJECT_WORKFLOW.md")
      config_path = Path.join(test_root, "symphony.yml")

      File.mkdir_p!(test_root)
      write_project_workflow_file!(workflow_path)

      write_symphony_config_file!(config_path,
        projects: [
          %{linear_project: "duplicate", workflow: "./PROJECT_WORKFLOW.md"},
          %{linear_project: "duplicate", workflow: "./PROJECT_WORKFLOW.md"}
        ]
      )

      SymphonyConfig.set_config_file_path(config_path)

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "duplicate project slug"
    after
      File.rm_rf(test_root)
    end
  end

  test "config route lookup matches bare Linear slugId against url-style project slug" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-global-config-route-normalization-#{System.unique_integer([:positive])}"
      )

    try do
      repo_root = Path.join(test_root, "repo")
      _workflow_path = Path.join(repo_root, "PROJECT_WORKFLOW.md")
      config_path = Path.join(test_root, "symphony.yml")

      init_repo!(repo_root, "route normalization\n")
      write_project_workflow_repo_file!(repo_root, "PROJECT_WORKFLOW.md")

      write_symphony_config_file!(config_path,
        projects: [
          %{
            linear_project: "project-a-1a2b3c4d5e6f",
            repo: repo_root,
            workflow: "./PROJECT_WORKFLOW.md"
          }
        ]
      )

      SymphonyConfig.set_config_file_path(config_path)

      settings = Config.settings!()
      issue = %Issue{identifier: "PI-22", project_slug: "1a2b3c4d5e6f"}

      assert %{slug: "project-a-1a2b3c4d5e6f"} = Config.linear_project_route(issue, settings)
      assert {:ok, issue_config} = SymphonyElixir.IssueConfig.resolve(issue)
      assert issue_config.project_route.slug == "project-a-1a2b3c4d5e6f"
    after
      File.rm_rf(test_root)
    end
  end

  test "project workflow accepts legacy runtime keys and partial provider overrides" do
    workflow_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-project-workflow-legacy-#{System.unique_integer([:positive])}.md"
      )

    try do
      File.write!(
        workflow_path,
        """
        ---
        tracker:
          kind: linear
        workspace:
          root: /tmp/ignored
        codex:
          command: codex app-server --model gpt-5.4
        agent:
          max_concurrent_agents: 5
          max_turns: 7
        ---
        Legacy-compatible project workflow
        """
      )

      assert {:ok, workflow} = ProjectWorkflow.load(workflow_path)

      assert workflow.codex.command == "codex app-server --model gpt-5.4"
      assert workflow.agent.max_concurrent_agents == 5
      assert workflow.agent.max_turns == 7
    after
      File.rm_rf(workflow_path)
    end
  end

  test "project workflow rejects unknown runtime keys in multi-project mode" do
    workflow_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-project-workflow-invalid-#{System.unique_integer([:positive])}.md"
      )

    try do
      File.write!(
        workflow_path,
        """
        ---
        bananas:
          kind: linear
        ---
        Invalid project workflow
        """
      )

      assert {:error, {:invalid_project_workflow_config, message}} =
               ProjectWorkflow.load(workflow_path)

      assert message =~ "unsupported key"
      assert message =~ "bananas"
    after
      File.rm_rf(workflow_path)
    end
  end

  test "issue config resolves project workflow prompt and backend precedence" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-config-#{System.unique_integer([:positive])}"
      )

    try do
      repo_root = Path.join(test_root, "project-b")
      _workflow_path = Path.join(repo_root, "CLAUDE_WORKFLOW.md")
      config_path = Path.join(test_root, "symphony.yml")

      init_repo!(repo_root, "project b\n")

      write_project_workflow_repo_file!(repo_root, "CLAUDE_WORKFLOW.md",
        default_effort: "high",
        max_turns: 7,
        prompt: "Project-specific prompt for {{ issue.identifier }}"
      )

      write_symphony_config_file!(config_path,
        default_effort: "low",
        max_turns: 20,
        projects: [
          %{
            linear_project: "project-b",
            repo: repo_root,
            workflow: "./CLAUDE_WORKFLOW.md",
            backend: "claude"
          }
        ]
      )

      SymphonyConfig.set_config_file_path(config_path)

      issue =
        %Issue{
          identifier: "AP-42",
          title: "Route through project workflow",
          project_slug: "project-b",
          labels: ["codex", "thinking/max"]
        }

      assert {:ok, issue_config} = SymphonyElixir.IssueConfig.resolve(issue)
      assert issue_config.settings.agent.backend == "claude"
      assert issue_config.settings.agent.default_effort == "high"
      assert issue_config.settings.agent.max_turns == 7
      assert PromptBuilder.build_prompt(issue, issue_config: issue_config) == "Project-specific prompt for AP-42"

      route = SymphonyElixir.AgentRoute.resolve(issue, issue_config.settings)
      assert route.backend == "codex"
      assert route.effort == "max"
    after
      File.rm_rf(test_root)
    end
  end

  test "issue config and workspace honor a project's configured default branch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-project-default-branch-#{System.unique_integer([:positive])}"
      )

    try do
      repo_root = Path.join(test_root, "project-b")
      config_path = Path.join(test_root, "symphony.yml")
      workspace_root = Path.join(test_root, "workspaces")

      init_repo!(repo_root, "project b\n")
      System.cmd("git", ["-C", repo_root, "checkout", "-b", "feature/example-branch"])
      File.write!(Path.join(repo_root, "ONLY_SWITCH_TO_TS"), "branch-specific\n")
      write_project_workflow_file!(Path.join(repo_root, "WORKFLOW.md"), prompt: "Branch workflow for {{ issue.identifier }}")
      System.cmd("git", ["-C", repo_root, "add", "WORKFLOW.md", "ONLY_SWITCH_TO_TS"])
      System.cmd("git", ["-C", repo_root, "commit", "-m", "Add branch workflow"])
      System.cmd("git", ["-C", repo_root, "checkout", "main"])

      write_symphony_config_file!(config_path,
        tracker_kind: "memory",
        workspace_root: workspace_root,
        projects: [
          %{
            linear_project: "project-b",
            repo: repo_root,
            workflow: "./WORKFLOW.md",
            default_branch: "feature/example-branch"
          }
        ]
      )

      SymphonyConfig.set_config_file_path(config_path)

      settings = Config.settings!()
      issue = %Issue{identifier: "AP-42", project_slug: "project-b"}

      assert [%{default_branch: "feature/example-branch"}] = Config.linear_project_routes(settings)
      assert {:ok, issue_config} = SymphonyElixir.IssueConfig.resolve(issue)
      assert PromptBuilder.build_prompt(issue, issue_config: issue_config) == "Branch workflow for AP-42"

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "ONLY_SWITCH_TO_TS")) == "branch-specific\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace auto-resolves project workflow hooks in symphony config mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-global-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      repo_root = Path.join(test_root, "product-source")
      _workflow_path = Path.join(repo_root, "PRODUCT_WORKFLOW.md")
      config_path = Path.join(test_root, "symphony.yml")
      workspace_root = Path.join(test_root, "workspaces")

      init_repo!(repo_root, "global workflow routing\n")

      write_project_workflow_repo_file!(repo_root, "PRODUCT_WORKFLOW.md", hook_after_create: "printf project-hook > .project-hook.txt")

      write_symphony_config_file!(config_path,
        workspace_root: workspace_root,
        projects: [
          %{
            linear_project: "project-a",
            repo: repo_root,
            workflow: "./PRODUCT_WORKFLOW.md"
          }
        ]
      )

      SymphonyConfig.set_config_file_path(config_path)

      issue = %Issue{identifier: "PI-22", project_slug: "project-a"}

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "README.md")) == "global workflow routing\n"
      assert File.read!(Path.join(workspace, ".project-hook.txt")) == "project-hook"
    after
      File.rm_rf(test_root)
    end
  end

  defp init_repo!(path, readme_contents) do
    File.mkdir_p!(path)
    File.write!(Path.join(path, "README.md"), readme_contents)
    System.cmd("git", ["-C", path, "init", "-b", "main"])
    System.cmd("git", ["-C", path, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", path, "add", "README.md"])
    System.cmd("git", ["-C", path, "commit", "-m", "initial"])
  end

  defp write_project_workflow_repo_file!(repo_path, relative_path, overrides \\ []) do
    workflow_path = Path.join(repo_path, relative_path)
    write_project_workflow_file!(workflow_path, overrides)
    System.cmd("git", ["-C", repo_path, "add", relative_path])
    System.cmd("git", ["-C", repo_path, "commit", "-m", "Add #{relative_path}"])
    workflow_path
  end
end
