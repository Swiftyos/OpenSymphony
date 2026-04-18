defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      opencode_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Backlog", "Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.agent.max_turns == 20

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_projects: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_projects: [
        %{slug: "project-a"},
        %{slug: "project-b"}
      ]
    )

    assert :ok = Config.validate!()
    assert Enum.map(Config.linear_project_routes(), & &1.slug) == ["project-a", "project-b"]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      opencode_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "opencode.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), opencode_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().opencode.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), opencode_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: linear
        api_key: token
        project_slug: project
      opencode:
        approval_policy: never
      ---
      You are an agent for this repository.
      """
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "`opencode.approval_policy` is no longer supported"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "current symphony.yml and project WORKFLOW.md files are valid and complete" do
    repo_root = File.cwd!()
    symphony_config_path = Path.join(repo_root, "symphony.yml")
    workflow_path = Path.join(repo_root, "WORKFLOW.md")

    assert {:ok, %{config: config}} = SymphonyConfig.load(symphony_config_path)
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    projects = Map.get(config, "projects", [])
    assert Enum.map(projects, &Map.get(&1, "linear_project")) == ["project-a", "project-b"]
    assert Enum.all?(projects, &(is_binary(Map.get(&1, "repo")) and Map.get(&1, "repo") != ""))
    assert Enum.all?(projects, &(is_binary(Map.get(&1, "workflow")) and Map.get(&1, "workflow") != ""))
    assert Enum.all?(projects, &(is_binary(Map.get(&1, "workspace_root")) and Map.get(&1, "workspace_root") != ""))
    assert Enum.all?(projects, &(Map.get(&1, "backend") in ["codex", "claude"]))

    assert {:ok, %{config: workflow_config, prompt: prompt}} = ProjectWorkflow.load(workflow_path)
    assert is_map(workflow_config)

    hooks = Map.get(workflow_config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") =~ "mise trust"
    assert Map.get(hooks, "after_create") =~ "mise exec -- mix deps.get"
    assert Map.get(hooks, "before_remove") =~ "cd elixir && mise exec -- mix workspace.before_remove"

    agent = Map.get(workflow_config, "agent", %{})
    assert is_map(agent)
    assert Map.get(agent, "default_effort") == "medium"
    assert Map.get(agent, "max_turns") == 20

    assert String.trim(prompt) != ""
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      opencode_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      opencode_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "openrouter api key resolves from OPENROUTER_API_KEY env var" do
    previous_openrouter_api_key = System.get_env("OPENROUTER_API_KEY")
    env_api_key = "test-openrouter-api-key"

    on_exit(fn -> restore_env("OPENROUTER_API_KEY", previous_openrouter_api_key) end)
    System.put_env("OPENROUTER_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      providers_openrouter_api_key: nil,
      tracker_project_slug: "project",
      opencode_command: "/bin/sh app-server"
    )

    assert Config.settings!().providers.openrouter_api_key == env_api_key
  end

  test "orchestrator startup fails fast when repository preflight fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-orchestrator-repo-preflight-#{System.unique_integer([:positive])}"
      )

    try do
      workflow_path = Path.join(test_root, "PROJECT_WORKFLOW.md")
      config_path = Path.join(test_root, "symphony.yml")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(test_root)
      write_project_workflow_file!(workflow_path)

      write_symphony_config_file!(config_path,
        tracker_kind: "memory",
        workspace_root: workspace_root,
        projects: [
          %{
            linear_project: "project-a",
            repo: "https://127.0.0.1:1/does-not-exist.git",
            workflow: "./PROJECT_WORKFLOW.md"
          }
        ]
      )

      SymphonyConfig.set_config_file_path(config_path)

      orchestrator_name = Module.concat(__MODULE__, :RepoPreflightCrashOrchestrator)
      previous_trap_exit = Process.flag(:trap_exit, true)

      on_exit(fn ->
        Process.flag(:trap_exit, previous_trap_exit)
      end)

      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               Orchestrator.start_link(name: orchestrator_name)

      assert message =~ "Repository preflight failed"
      assert message =~ "127.0.0.1:1/does-not-exist.git"
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "issue moved to Backlog stops running agent and cleans workspace by default" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-backlog-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-backlog"
    issue_identifier = "MT-558"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: nil,
        tracker_terminal_states: nil
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Deprioritized",
        description: "Moved back to backlog mid-run",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, 500, 1_100)
  end

  test "continuation retry cleans workspace when issue is terminal" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-retry-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-terminal-retry"
    issue_identifier = "MT-559"
    retry_token = make_ref()
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Cancelled", "Done"]
      )

      File.mkdir_p!(workspace)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{
          id: issue_id,
          identifier: issue_identifier,
          title: "Finished work",
          state: "Done"
        }
      ])

      state = %Orchestrator.State{
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{
          issue_id => %{
            attempt: 1,
            retry_token: retry_token,
            timer_ref: nil,
            due_at_ms: System.monotonic_time(:millisecond),
            identifier: issue_identifier,
            worker_host: nil,
            workspace_path: workspace
          }
        },
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      assert {:noreply, updated_state} =
               Orchestrator.handle_info({:retry_issue, issue_id, retry_token}, state)

      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Map.has_key?(updated_state.retry_attempts, issue_id)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 39_500, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test returns nil when no ssh workers are configured" do
    state = %Orchestrator.State{running: %{}}

    assert Orchestrator.select_worker_host_for_test(state, nil) == nil
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    slack_ms = 1_000
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= max(min_remaining_ms - slack_ms, 0)
    assert remaining_ms <= max_remaining_ms + slack_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on a Linear ticket `MT-616`"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "This is an unattended orchestration session."
    assert prompt =~ "Only stop early for a true blocker"
    assert prompt =~ "Do not include \"next steps for user\""
    assert prompt =~ "open and follow `.codex/skills/land/SKILL.md`"
    assert prompt =~ "do not call `gh pr merge` directly"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "agent runner keeps workspace after successful OpenCode run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)
      server = start_fake_opencode_server!()
      launcher = write_opencode_launcher_script!(test_root, server.base_url)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf '# test\\n' > README.md",
        opencode_command: launcher
      )

      issue = issue_fixture("issue-keep-workspace", "S-99", "Smoke test")

      before = MapSet.new(File.ls!(workspace_root))

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.read!(Path.join(workspace, "README.md")) == "# test\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped agent updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)
      server = start_fake_opencode_server!()
      launcher = write_opencode_launcher_script!(test_root, server.base_url)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf '# test\\n' > README.md",
        opencode_command: launcher
      )

      issue = issue_fixture("issue-live-updates", "MT-99", "Smoke test")

      assert :ok =
               AgentRunner.run(
                 issue,
                 self(),
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:worker_runtime_info, "issue-live-updates", %{workspace_path: workspace_path}}, 1_000
      assert workspace_path =~ "MT-99"

      assert_receive {:agent_worker_update, "issue-live-updates",
                      %{
                        event: :turn_started,
                        timestamp: %DateTime{},
                        session_id: "session-core"
                      }},
                     1_000

      assert_receive {:agent_worker_update, "issue-live-updates",
                      %{
                        event: :turn_completed,
                        timestamp: %DateTime{},
                        session_id: "session-core"
                      }},
                     1_000
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)
      server = start_fake_opencode_server!()
      launcher = write_opencode_launcher_script!(test_root, server.base_url)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf '# test\\n' > README.md",
        opencode_command: launcher,
        max_turns: 3
      )

      issue = issue_fixture("issue-continue", "MT-247", "Continue until done")
      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok, [%{issue | state: state}]}
      end

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}, 1_000
      assert_receive {:issue_state_fetch, 2}, 1_000

      assert :ok =
               __MODULE__.FakeOpenCodeState.wait_until(server.state, fn current ->
                 length(current.message_posts) == 2
               end)

      prompts =
        server.state
        |> __MODULE__.FakeOpenCodeState.message_posts()
        |> Enum.map(&message_text/1)

      assert length(prompts) == 2
      assert Enum.at(prompts, 0) =~ "You are an agent for this repository."
      refute Enum.at(prompts, 1) =~ "You are an agent for this repository."
      assert Enum.at(prompts, 1) =~ "Continuation guidance:"
      assert Enum.at(prompts, 1) =~ "continuation turn #2 of 3"
    after
      Process.delete(:agent_turn_fetch_count)
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)
      server = start_fake_opencode_server!()
      launcher = write_opencode_launcher_script!(test_root, server.base_url)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf '# test\\n' > README.md",
        opencode_command: launcher,
        max_turns: 2
      )

      issue = issue_fixture("issue-max-turns", "MT-248", "Stop at max turns")

      state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      assert :ok =
               __MODULE__.FakeOpenCodeState.wait_until(server.state, fn current ->
                 length(current.message_posts) == 2
               end)

      posts = __MODULE__.FakeOpenCodeState.message_posts(server.state)
      assert length(posts) == 2
      assert Enum.all?(posts, &(&1.session_id == "session-core"))
    after
      File.rm_rf(test_root)
    end
  end

  test "app server uses the configured startup command and workspace cwd" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      trace_file = Path.join(test_root, "opencode-args.trace")
      File.mkdir_p!(workspace)
      server = start_fake_opencode_server!()
      launcher = write_opencode_launcher_script!(test_root, server.base_url, trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        opencode_command: "#{launcher} --hostname 0.0.0.0 --port 4444"
      )

      assert {:ok, _result} =
               AppServer.run(workspace, "Fix workspace start args", issue_fixture("issue-args", "MT-77", "Validate args"))

      trace = File.read!(trace_file)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
      assert trace =~ "ARGV:--hostname 0.0.0.0 --port 4444"
      assert trace =~ "CWD:#{canonical_workspace}"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server uses command args from workflow config verbatim" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      trace_file = Path.join(test_root, "opencode-custom-args.trace")
      File.mkdir_p!(workspace)
      server = start_fake_opencode_server!()
      launcher = write_opencode_launcher_script!(test_root, server.base_url, trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        opencode_command: "#{launcher} --foo bar --baz qux"
      )

      assert {:ok, _result} =
               AppServer.run(workspace, "Fix workspace start args", issue_fixture("issue-custom-args", "MT-88", "Validate custom args"))

      trace = File.read!(trace_file)
      assert trace =~ "ARGV:--foo bar --baz qux"
    after
      File.rm_rf(test_root)
    end
  end

  defmodule FakeOpenCodeState do
    use Agent

    def start_link(opts) do
      Agent.start_link(fn ->
        %{
          test_pid: Keyword.fetch!(opts, :test_pid),
          session_creates: [],
          message_posts: [],
          subscribers: MapSet.new()
        }
      end)
    end

    def subscribe(state, pid) do
      Agent.update(state, fn current ->
        %{current | subscribers: MapSet.put(current.subscribers, pid)}
      end)
    end

    def record_session_create(state, body) do
      Agent.update(state, fn current ->
        %{current | session_creates: [body | current.session_creates]}
      end)

      notify(state, {:session_create, body})
    end

    def record_message_post(state, session_id, body) do
      entry =
        Agent.get_and_update(state, fn current ->
          entry = %{
            index: length(current.message_posts) + 1,
            session_id: session_id,
            body: body
          }

          {entry, %{current | message_posts: [entry | current.message_posts]}}
        end)

      notify(state, {:message_post, entry})
      entry
    end

    def message_posts(state) do
      Agent.get(state, fn current -> Enum.reverse(current.message_posts) end)
    end

    def wait_until(state, predicate, timeout_ms \\ 1_000) when is_function(predicate, 1) do
      deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
      do_wait_until(state, predicate, deadline_ms)
    end

    defp do_wait_until(state, predicate, deadline_ms) do
      if predicate.(Agent.get(state, & &1)) do
        :ok
      else
        if System.monotonic_time(:millisecond) >= deadline_ms do
          {:error, :timeout}
        else
          Process.sleep(10)
          do_wait_until(state, predicate, deadline_ms)
        end
      end
    end

    defp notify(state, message) do
      test_pid = Agent.get(state, & &1.test_pid)
      send(test_pid, {:fake_opencode_request, message})
      :ok
    end
  end

  defmodule FakeOpenCodePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      state = Keyword.fetch!(opts, :state)

      case {conn.method, String.split(conn.request_path, "/", trim: true)} do
        {"GET", ["global", "health"]} ->
          json(conn, 200, %{"healthy" => true})

        {"GET", ["global", "event"]} ->
          stream_events(conn, state)

        {"POST", ["session"]} ->
          body = read_json_body!(conn)
          SymphonyElixir.CoreTest.FakeOpenCodeState.record_session_create(state, body)
          json(conn, 200, %{"id" => "session-core"})

        {"POST", ["session", session_id, "message"]} ->
          body = read_json_body!(conn)
          entry = SymphonyElixir.CoreTest.FakeOpenCodeState.record_message_post(state, session_id, body)

          json(conn, 200, %{
            "info" => %{
              "id" => "assistant-#{entry.index}",
              "sessionID" => session_id,
              "tokens" => %{"input" => 8 + entry.index, "output" => entry.index, "reasoning" => 0}
            }
          })

        {"POST", ["session", _session_id, "abort"]} ->
          json(conn, 200, %{"ok" => true})

        _ ->
          send_resp(conn, 404, "not found")
      end
    end

    defp stream_events(conn, state) do
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      SymphonyElixir.CoreTest.FakeOpenCodeState.subscribe(state, self())
      wait_for_disconnect(conn)
    end

    defp wait_for_disconnect(conn) do
      receive do
        :close -> conn
      after
        30_000 -> conn
      end
    end

    defp read_json_body!(conn) do
      {:ok, body, _conn} = read_body(conn)

      case body do
        "" -> %{}
        payload -> Jason.decode!(payload)
      end
    end

    defp json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  defp start_fake_opencode_server! do
    {:ok, state} = start_supervised({__MODULE__.FakeOpenCodeState, test_pid: self()})
    bandit = start_supervised!({Bandit, plug: {__MODULE__.FakeOpenCodePlug, state: state}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    %{state: state, base_url: "http://127.0.0.1:#{port}"}
  end

  defp write_opencode_launcher_script!(test_root, base_url, trace_file \\ nil) do
    launcher = Path.join(test_root, "fake-opencode-launcher.sh")

    trace_commands =
      if is_binary(trace_file) do
        """
        printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
        printf 'CWD:%s\\n' "$PWD" >> "#{trace_file}"
        """
      else
        ""
      end

    File.write!(launcher, """
    #!/bin/sh
    #{trace_commands}
    printf 'opencode server listening on #{base_url}\\n'
    while true; do
      sleep 1
    done
    """)

    File.chmod!(launcher, 0o755)
    launcher
  end

  defp message_text(%{body: %{"parts" => [part | _]}}) when is_map(part) do
    Map.get(part, "text", "")
  end

  defp message_text(_entry), do: ""

  defp issue_fixture(id, identifier, title) do
    %Issue{
      id: id,
      identifier: identifier,
      title: title,
      description: "Exercise the OpenCode core test harness",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: ["backend"]
    }
  end
end
