defmodule SymphonyElixir.MultiRepoTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Factory.{Definition, Store}
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.{RepoPrompt, Unblocker}

  defmodule FakeLinear do
    def graphql(_query, variables, _opts \\ []), do: Application.get_env(:symphony_elixir, :multi_repo_linear_reply).(variables)
  end

  describe "home repo" do
    test "the repo/<name> label picks the issue's repo, else the primary" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: nil,
        tracker_projects: [
          %{slug: "project-a", repo: "acme/api", default_branch: "main", repos: [%{name: "worker", repo: "acme/jobs-worker", default_branch: "trunk"}]}
        ]
      )

      settings = Config.settings!()
      plain = %Issue{identifier: "PI-1", project_slug: "project-a", labels: []}
      worker = %Issue{identifier: "PI-2", project_slug: "project-a", labels: ["repo/worker"]}
      unknown = %Issue{identifier: "PI-3", project_slug: "project-a", labels: ["repo/nope"]}

      assert %{name: "api", primary: true} = Config.issue_repo(plain, settings)
      assert %{name: "worker", repo: "acme/jobs-worker"} = Config.issue_repo(worker, settings)
      assert Config.project_repo_for_issue(worker, settings) == "acme/jobs-worker"
      assert Config.project_default_branch_for_issue(worker, settings) == "trunk"
      assert Config.project_default_branch_for_issue(plain, settings) == "main"
      assert %{name: "api"} = Config.issue_repo(unknown, settings)
    end

    test "repo names come from the last path segment" do
      assert Config.repo_name("acme/Payments-API") == "payments-api"
      assert Config.repo_name("git@github.com:acme/worker.git") == "worker"
      assert Config.repo_name("/srv/repos/billing/") == "billing"
    end

    test "a single-repo project has no extra repos and no repositories prompt" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: nil,
        tracker_projects: [%{slug: "project-a", repo: "acme/api"}]
      )

      issue = %Issue{identifier: "PI-1", project_slug: "project-a", state: "In Progress", labels: ["factory/implement"]}
      assert [%{name: "api", primary: true}] = Config.project_repos(Config.linear_project_route(issue))
      assert RepoPrompt.render(issue) == ""
    end
  end

  describe "workspaces" do
    test "the home repo is the workspace and the other repos are read-only references" do
      test_root = Path.join(System.tmp_dir!(), "symphony-multi-repo-#{System.unique_integer([:positive])}")
      api = Path.join(test_root, "api")
      worker = Path.join(test_root, "worker")

      try do
        init_repo!(api, "api v1\n")
        init_repo!(worker, "worker v1\n")

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_project_slug: nil,
          tracker_projects: [%{slug: "project-a", repo: api, repos: [%{name: "worker", repo: worker}]}],
          workspace_root: Path.join(test_root, "workspaces")
        )

        settings = put_in(Config.settings!().workspace.repo_cache.max_age_ms, 0)

        primary_issue = %Issue{id: "i-1", identifier: "PI-1", project_slug: "project-a", labels: []}
        assert {:ok, workspace} = Workspace.create_for_issue(primary_issue, nil, settings: settings)
        assert File.read!(Path.join(workspace, "README.md")) == "api v1\n"
        assert File.read!(Path.join(workspace, ".symphony/repos/worker/README.md")) == "worker v1\n"
        refute File.exists?(Path.join(workspace, ".symphony/repos/api"))

        worker_issue = %Issue{id: "i-2", identifier: "PI-2", project_slug: "project-a", labels: ["repo/worker"]}
        assert {:ok, worker_workspace} = Workspace.create_for_issue(worker_issue, nil, settings: settings)
        assert File.read!(Path.join(worker_workspace, "README.md")) == "worker v1\n"
        assert {"symphony/PI-2\n", 0} = System.cmd("git", ["-C", worker_workspace, "branch", "--show-current"])
        assert File.read!(Path.join(worker_workspace, ".symphony/repos/api/README.md")) == "api v1\n"

        # The next run of the first issue sees the worker repo's latest default branch.
        commit_file!(worker, "README.md", "worker v2\n", "fix in worker")
        File.write!(Path.join(workspace, ".symphony/repos/worker/README.md"), "local edit\n")

        assert {:ok, ^workspace} = Workspace.create_for_issue(primary_issue, nil, settings: settings)
        assert File.read!(Path.join(workspace, ".symphony/repos/worker/README.md")) == "worker v2\n"
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "run spec routes" do
    test "a runner given the spec's route and workspace root checks out the issue's home repo and the references" do
      test_root = Path.join(System.tmp_dir!(), "symphony-multi-repo-spec-#{System.unique_integer([:positive])}")
      api = Path.join(test_root, "api")
      worker = Path.join(test_root, "worker")

      try do
        init_repo!(api, "api v1\n")
        init_repo!(worker, "worker v1\n")

        # The runner's own config doesn't have the project (added through MCP).
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_project_slug: nil,
          tracker_projects: [%{slug: "other", repo: api}],
          workspace_root: Path.join(test_root, "elsewhere")
        )

        settings = put_in(Config.settings!().workspace.repo_cache.max_age_ms, 0)
        # The controller resolved `root/<slug>` (it has several routes); still under the root.
        workspace_root = Path.join([test_root, "elsewhere", "project-a"])

        route = %{
          slug: "project-a",
          repo: api,
          default_branch: nil,
          repos: [%{name: "worker", repo: worker, default_branch: nil, description: nil}]
        }

        issue = %Issue{id: "i-9", identifier: "PI-9", project_slug: "project-a", labels: ["repo/worker"]}

        opts = [settings: settings, project_route: route, workspace_root: workspace_root]
        assert {:ok, workspace} = Workspace.create_for_issue(issue, nil, opts)

        assert String.contains?(workspace, "/elsewhere/project-a/")
        assert File.read!(Path.join(workspace, "README.md")) == "worker v1\n"
        assert {"symphony/PI-9\n", 0} = System.cmd("git", ["-C", workspace, "branch", "--show-current"])
        assert File.read!(Path.join(workspace, ".symphony/repos/api/README.md")) == "api v1\n"
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "repositories prompt" do
    test "names the home repo, the references, and how to block on another repo" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: nil,
        tracker_projects: [
          %{slug: "project-a", repo: "acme/api", repos: [%{name: "worker", repo: "acme/jobs-worker", description: "Queue consumers"}]}
        ]
      )

      issue = %Issue{id: "i-1", identifier: "PI-1", project_slug: "project-a", state: "In Progress", labels: ["factory/implement"]}
      prompt = RepoPrompt.render(issue)

      assert prompt =~ "## Repositories"
      assert prompt =~ "This issue is worked in **api** (`acme/api`)"
      assert prompt =~ "**worker** (`acme/jobs-worker`) at `.symphony/repos/worker`: Queue consumers"
      assert prompt =~ "`repo/worker`"
      assert prompt =~ "type: blocks"
      # New blocker issues go to the flow's queue state.
      assert prompt =~ "in the `Todo` state"
      assert prompt =~ "with the move `blocked` (Blocked)"

      assert %{"name" => "api", "others" => [%{"name" => "worker", "path" => ".symphony/repos/worker"}]} = RepoPrompt.variables(issue)
      assert PromptBuilder.build_prompt(issue) =~ "## Repositories"

      # From a stage with no move to a parked stage, a person takes it.
      review = %{issue | state: "In Review", labels: []}
      assert RepoPrompt.render(review) =~ "this stage has no move to a blocked stage"
      # Outside any stage too.
      assert RepoPrompt.render(%{issue | state: "Backlog", labels: []}) =~ "this stage has no move to a blocked stage"

      assert RepoPrompt.render(nil) == ""
      assert RepoPrompt.variables(nil) == %{"name" => nil, "repo" => nil, "others" => []}
    end

    test "blocker issues are filed in the flow's queue state" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: nil,
        tracker_projects: [%{slug: "project-a", repo: "acme/api", repos: [%{name: "worker", repo: "acme/jobs-worker"}]}]
      )

      flow =
        Definition.default_template()
        |> Map.update!("stages", fn stages ->
          Enum.map(stages, fn
            %{"id" => "todo"} = stage -> %{stage | "linear_state" => "Ready for pickup"}
            stage -> stage
          end)
        end)

      {:ok, _} = Store.put("project:project-a", flow, 0, "test")
      on_exit(fn -> Store.reset() end)

      issue = %Issue{id: "i-1", identifier: "PI-1", project_slug: "project-a", state: "In Progress", labels: ["factory/implement"]}
      assert RepoPrompt.render(issue) =~ "in the `Ready for pickup` state"
    end

    test "a repo needs a name and a repo" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: nil,
        tracker_projects: [%{slug: "project-a", repo: "acme/api", repos: [%{repo: "acme/worker"}]}]
      )

      assert {:error, _} = Config.settings()
    end
  end

  describe "unblocking" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issue_reports) end)
      :ok
    end

    test "a blocked issue whose blockers are all done goes back to implement with what they did" do
      issue = blocked_issue([%{id: "b-1", identifier: "PI-2", state: "Done", state_type: "completed"}])
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      Application.put_env(:symphony_elixir, :memory_tracker_issue_reports, %{
        "b-1" => %{
          id: "b-1",
          identifier: "PI-2",
          title: "Retry jobs in the worker",
          url: "https://linear.app/acme/issue/PI-2",
          state: "Done",
          state_type: "completed",
          attachments: [%{title: "Retry failed jobs #42", url: "https://github.com/acme/jobs-worker/pull/42"}],
          comments: [
            "## Merge\n\nMerged #42.\n\n_Moved to Done by Agent Factory._",
            "## Implement\n\nThe worker now retries failed jobs three times.\n\n_Moved to In Review by Agent Factory._",
            "Looks good to me"
          ]
        }
      })

      assert Unblocker.ready?(issue)
      assert :ok = Unblocker.unblock(issue)

      assert_received {:memory_tracker_comment, "i-1", body}
      assert body =~ "## Unblocked"
      assert body =~ "moved it back to **Implement**"
      assert body =~ "### PI-2 · Retry jobs in the worker (Done)"
      assert body =~ "https://github.com/acme/jobs-worker/pull/42"
      assert body =~ "> The worker now retries failed jobs three times."
      assert body =~ "> Merged #42."
      refute body =~ "Looks good to me"
      refute body =~ "_Moved to"

      assert_received {:memory_tracker_stage_update, "i-1", "In Progress", "implement"}

      # The issue has moved on, so nothing happens again.
      [moved] = Application.get_env(:symphony_elixir, :memory_tracker_issues)
      refute Unblocker.ready?(moved)
      assert :skipped = Unblocker.unblock(issue)
    end

    test "it stays blocked while a blocker is open or was cancelled, or when nothing blocks it" do
      refute Unblocker.ready?(blocked_issue([%{id: "b-1", identifier: "PI-2", state: "In Progress", state_type: "started"}]))
      refute Unblocker.ready?(blocked_issue([%{id: "b-1", identifier: "PI-2", state: "Canceled", state_type: "canceled"}]))

      refute Unblocker.ready?(
               blocked_issue([
                 %{id: "b-1", identifier: "PI-2", state: "Done", state_type: "completed"},
                 %{id: "b-2", identifier: "PI-3", state: "Todo", state_type: "unstarted"}
               ])
             )

      refute Unblocker.ready?(blocked_issue([]))
      refute Unblocker.ready?(%{})

      # A tracker without state types: the state named Done counts.
      assert Unblocker.ready?(blocked_issue([%{id: "b-1", identifier: "PI-2", state: "Done"}]))
      refute Unblocker.ready?(blocked_issue([%{id: "b-1", identifier: "PI-2"}]))

      # Blockers matter only for a parked issue.
      implementing = %{blocked_issue([%{id: "b-1", identifier: "PI-2", state: "Done", state_type: "completed"}]) | labels: ["factory/implement"]}
      refute Unblocker.ready?(implementing)
    end

    test "an issue that has gone from the tracker is skipped" do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      assert :skipped = Unblocker.unblock(blocked_issue([%{id: "b-1", identifier: "PI-2", state: "Done", state_type: "completed"}]))
      refute_received {:memory_tracker_comment, _, _}
    end

    test "the server ignores stray messages" do
      pid = start_supervised!({Unblocker, name: :unblocker_test})
      send(pid, {:DOWN, make_ref(), :process, self(), :normal})
      send(pid, :stray)
      assert %{in_flight: %{}} = :sys.get_state(pid)
    end

    test "observe/1 unblocks ready issues in the background" do
      issue = blocked_issue([%{id: "b-1", identifier: "PI-2", state: "Done", state_type: "completed"}])
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert :ok = Unblocker.observe([issue, blocked_issue([])])
      assert_receive {:memory_tracker_stage_update, "i-1", "In Progress", "implement"}, 2_000
      assert_received {:memory_tracker_comment, "i-1", body}
      assert body =~ "No Agent Factory summary on it"

      # A person parks it again with the same (done) blockers: it stays parked.
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      wait_until(fn -> MapSet.size(:sys.get_state(Unblocker).done) > 0 end)
      assert :ok = Unblocker.observe([issue])
      :sys.get_state(Unblocker)
      refute_receive {:memory_tracker_stage_update, "i-1", _, _}, 300
    end
  end

  describe "queued issues with blockers" do
    test "wait in a queue state that isn't called Todo, until their blockers are done" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["Ready for pickup", "In Progress"])

      flow =
        Definition.default_template()
        |> Map.update!("stages", fn stages ->
          Enum.map(stages, fn
            %{"id" => "todo"} = stage -> %{stage | "linear_state" => "Ready for pickup"}
            stage -> stage
          end)
        end)

      {:ok, _} = Store.put("project:project", flow, 0, "test")
      on_exit(fn -> Store.reset() end)

      state = %Orchestrator.State{
        max_concurrent_agents: 5,
        running: %{},
        claimed: MapSet.new(),
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      queued = fn blockers ->
        %Issue{id: "i-9", identifier: "PI-9", title: "Queued", state: "Ready for pickup", labels: [], project_slug: "project", blocked_by: blockers}
      end

      refute Orchestrator.should_dispatch_issue_for_test(queued.([%{id: "b", identifier: "PI-8", state: "In Progress"}]), state)
      assert Orchestrator.should_dispatch_issue_for_test(queued.([%{id: "b", identifier: "PI-8", state: "Done"}]), state)
      assert Orchestrator.should_dispatch_issue_for_test(queued.([]), state)
    end
  end

  describe "Linear issue reports" do
    setup do
      Application.put_env(:symphony_elixir, :linear_client_module, FakeLinear)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :linear_client_module)
        Application.delete_env(:symphony_elixir, :multi_repo_linear_reply)
      end)
    end

    test "reads title, state, attachments and comments newest first" do
      Application.put_env(:symphony_elixir, :multi_repo_linear_reply, fn %{ids: ["b-1"]} ->
        {:ok,
         %{
           "data" => %{
             "issues" => %{
               "nodes" => [
                 %{
                   "id" => "b-1",
                   "identifier" => "PI-2",
                   "title" => "Retry jobs",
                   "url" => "https://linear.app/x/PI-2",
                   "state" => %{"name" => "Done", "type" => "completed"},
                   "attachments" => %{"nodes" => [%{"title" => "PR", "url" => "https://github.com/x/pull/1"}, %{"title" => "no url"}]},
                   "comments" => %{
                     "nodes" => [
                       %{"body" => "older", "createdAt" => "2026-01-01T00:00:00Z"},
                       %{"body" => "newer", "createdAt" => "2026-01-02T00:00:00Z"},
                       %{"body" => nil}
                     ]
                   }
                 }
               ]
             }
           }
         }}
      end)

      assert {:ok, [report]} = Adapter.fetch_issue_reports(["b-1"])
      assert %{identifier: "PI-2", state_type: "completed", attachments: [%{url: "https://github.com/x/pull/1"}], comments: ["newer", "older"]} = report
      assert {:ok, []} = Adapter.fetch_issue_reports([])
    end

    test "errors and odd answers come back as errors" do
      Application.put_env(:symphony_elixir, :multi_repo_linear_reply, fn _ -> {:error, :down} end)
      assert {:error, :down} = Adapter.fetch_issue_reports(["b-1"])

      Application.put_env(:symphony_elixir, :multi_repo_linear_reply, fn _ -> {:ok, %{"errors" => []}} end)
      assert {:error, {:unexpected_response, _}} = Adapter.fetch_issue_reports(["b-1"])
    end
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end

  defp blocked_issue(blockers) do
    %Issue{
      id: "i-1",
      identifier: "PI-1",
      title: "Errors in the API",
      project_slug: "project",
      state: "In Progress",
      labels: ["factory/blocked"],
      blocked_by: blockers
    }
  end

  defp init_repo!(path, readme_contents) do
    File.mkdir_p!(path)
    File.write!(Path.join(path, "README.md"), readme_contents)
    System.cmd("git", ["-C", path, "init", "-q", "-b", "main"])
    System.cmd("git", ["-C", path, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", path, "add", "README.md"])
    System.cmd("git", ["-C", path, "commit", "-q", "-m", "initial"])
  end

  defp commit_file!(repo, relative_path, contents, message) do
    File.write!(Path.join(repo, relative_path), contents)
    System.cmd("git", ["-C", repo, "add", relative_path])
    System.cmd("git", ["-C", repo, "commit", "-q", "-m", message])
  end
end
