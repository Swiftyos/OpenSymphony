defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.AppServer
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.ProjectWorkflow
      alias SymphonyElixir.SymphonyConfig
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          write_project_workflow_file!: 1,
          write_project_workflow_file!: 2,
          write_symphony_config_file!: 1,
          write_symphony_config_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0,
          stop_default_orchestrator: 0
        ]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_orchestrator()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :symphony_config_path)
          Application.delete_env(:symphony_elixir, :startup_mode)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def write_project_workflow_file!(path, overrides \\ []) do
    workflow = project_workflow_content(overrides)
    File.write!(path, workflow)
    :ok
  end

  def write_symphony_config_file!(path, overrides \\ []) do
    config = symphony_config_content(path, overrides)
    File.write!(path, config)

    if Process.whereis(SymphonyElixir.SymphonyConfigStore) do
      try do
        SymphonyElixir.SymphonyConfigStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  def stop_default_orchestrator do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.Orchestrator, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.Orchestrator, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_projects: nil,
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          providers_openrouter_api_key: nil,
          agent_backend: "opencode",
          default_effort: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          opencode_command: "opencode serve --hostname 127.0.0.1 --port 0",
          opencode_agent: "build",
          opencode_model: nil,
          opencode_turn_timeout_ms: 3_600_000,
          opencode_read_timeout_ms: 5_000,
          opencode_stall_timeout_ms: 300_000,
          claude_command: "claude",
          claude_model: nil,
          claude_permission_mode: "bypassPermissions",
          claude_turn_timeout_ms: 3_600_000,
          claude_read_timeout_ms: 5_000,
          claude_stall_timeout_ms: 300_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          telemetry_enabled: false,
          telemetry_otlp_endpoint: nil,
          telemetry_otlp_protocol: "grpc",
          telemetry_include_traces: true,
          telemetry_include_metrics: true,
          telemetry_include_logs: true,
          telemetry_resource_attributes: %{},
          server_port: nil,
          server_host: nil,
          instance_name: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_projects = Keyword.get(config, :tracker_projects)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    providers_openrouter_api_key = Keyword.get(config, :providers_openrouter_api_key)
    agent_backend = Keyword.get(config, :agent_backend)
    default_effort = Keyword.get(config, :default_effort)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    opencode_command = Keyword.get(config, :opencode_command)
    opencode_agent = Keyword.get(config, :opencode_agent)
    opencode_model = Keyword.get(config, :opencode_model)
    opencode_turn_timeout_ms = Keyword.get(config, :opencode_turn_timeout_ms)
    opencode_read_timeout_ms = Keyword.get(config, :opencode_read_timeout_ms)
    opencode_stall_timeout_ms = Keyword.get(config, :opencode_stall_timeout_ms)
    claude_command = Keyword.get(config, :claude_command)
    claude_model = Keyword.get(config, :claude_model)
    claude_permission_mode = Keyword.get(config, :claude_permission_mode)
    claude_turn_timeout_ms = Keyword.get(config, :claude_turn_timeout_ms)
    claude_read_timeout_ms = Keyword.get(config, :claude_read_timeout_ms)
    claude_stall_timeout_ms = Keyword.get(config, :claude_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    telemetry_enabled = Keyword.get(config, :telemetry_enabled)
    telemetry_otlp_endpoint = Keyword.get(config, :telemetry_otlp_endpoint)
    telemetry_otlp_protocol = Keyword.get(config, :telemetry_otlp_protocol)
    telemetry_include_traces = Keyword.get(config, :telemetry_include_traces)
    telemetry_include_metrics = Keyword.get(config, :telemetry_include_metrics)
    telemetry_include_logs = Keyword.get(config, :telemetry_include_logs)
    telemetry_resource_attributes = Keyword.get(config, :telemetry_resource_attributes)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    instance_name = Keyword.get(config, :instance_name)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  projects: #{yaml_value(tracker_projects)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        providers_yaml(providers_openrouter_api_key),
        "agent:",
        "  backend: #{yaml_value(agent_backend)}",
        "  default_effort: #{yaml_value(default_effort)}",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        "opencode:",
        "  command: #{yaml_value(opencode_command)}",
        "  agent: #{yaml_value(opencode_agent)}",
        "  model: #{yaml_value(opencode_model)}",
        "  turn_timeout_ms: #{yaml_value(opencode_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(opencode_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(opencode_stall_timeout_ms)}",
        "claude:",
        "  command: #{yaml_value(claude_command)}",
        "  model: #{yaml_value(claude_model)}",
        "  permission_mode: #{yaml_value(claude_permission_mode)}",
        "  turn_timeout_ms: #{yaml_value(claude_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(claude_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(claude_stall_timeout_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        telemetry_yaml(telemetry_enabled, telemetry_otlp_endpoint, telemetry_otlp_protocol, telemetry_include_traces, telemetry_include_metrics, telemetry_include_logs, telemetry_resource_attributes),
        server_yaml(server_port, server_host),
        instance_yaml(instance_name),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp project_workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          default_effort: nil,
          max_turns: nil,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          prompt: @workflow_prompt
        ],
        overrides
      )

    default_effort = Keyword.get(config, :default_effort)
    max_turns = Keyword.get(config, :max_turns)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        project_hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        project_agent_yaml(default_effort, max_turns),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp symphony_config_content(_path, overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          providers_openrouter_api_key: nil,
          agent_backend: "codex",
          default_effort: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          opencode_command: "opencode serve --hostname 127.0.0.1 --port 0",
          opencode_agent: "build",
          opencode_model: nil,
          opencode_turn_timeout_ms: 3_600_000,
          opencode_read_timeout_ms: 5_000,
          opencode_stall_timeout_ms: 300_000,
          claude_command: "claude",
          claude_model: nil,
          claude_permission_mode: "bypassPermissions",
          claude_turn_timeout_ms: 3_600_000,
          claude_read_timeout_ms: 5_000,
          claude_stall_timeout_ms: 300_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          telemetry_enabled: false,
          telemetry_otlp_endpoint: nil,
          telemetry_otlp_protocol: "grpc",
          telemetry_include_traces: true,
          telemetry_include_metrics: true,
          telemetry_include_logs: true,
          telemetry_resource_attributes: %{},
          server_port: nil,
          server_host: nil,
          instance_name: nil,
          projects: [
            %{
              linear_project: "project",
              workflow: "./PROJECT_WORKFLOW.md"
            }
          ]
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    providers_openrouter_api_key = Keyword.get(config, :providers_openrouter_api_key)
    agent_backend = Keyword.get(config, :agent_backend)
    default_effort = Keyword.get(config, :default_effort)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    opencode_command = Keyword.get(config, :opencode_command)
    opencode_agent = Keyword.get(config, :opencode_agent)
    opencode_model = Keyword.get(config, :opencode_model)
    opencode_turn_timeout_ms = Keyword.get(config, :opencode_turn_timeout_ms)
    opencode_read_timeout_ms = Keyword.get(config, :opencode_read_timeout_ms)
    opencode_stall_timeout_ms = Keyword.get(config, :opencode_stall_timeout_ms)
    claude_command = Keyword.get(config, :claude_command)
    claude_model = Keyword.get(config, :claude_model)
    claude_permission_mode = Keyword.get(config, :claude_permission_mode)
    claude_turn_timeout_ms = Keyword.get(config, :claude_turn_timeout_ms)
    claude_read_timeout_ms = Keyword.get(config, :claude_read_timeout_ms)
    claude_stall_timeout_ms = Keyword.get(config, :claude_stall_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    telemetry_enabled = Keyword.get(config, :telemetry_enabled)
    telemetry_otlp_endpoint = Keyword.get(config, :telemetry_otlp_endpoint)
    telemetry_otlp_protocol = Keyword.get(config, :telemetry_otlp_protocol)
    telemetry_include_traces = Keyword.get(config, :telemetry_include_traces)
    telemetry_include_metrics = Keyword.get(config, :telemetry_include_metrics)
    telemetry_include_logs = Keyword.get(config, :telemetry_include_logs)
    telemetry_resource_attributes = Keyword.get(config, :telemetry_resource_attributes)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    instance_name = Keyword.get(config, :instance_name)

    projects =
      Keyword.get(config, :projects)
      |> Enum.map(fn project ->
        project
        |> Map.new()
        |> Map.update("workflow", nil, fn workflow ->
          if is_binary(workflow) and workflow not in ["", nil] and
               Path.type(workflow) != :absolute and
               not String.starts_with?(workflow, ["./", "../", "~/"]) do
            "./" <> workflow
          else
            workflow
          end
        end)
      end)

    sections =
      [
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        providers_yaml(providers_openrouter_api_key),
        "agent:",
        "  backend: #{yaml_value(agent_backend)}",
        "  default_effort: #{yaml_value(default_effort)}",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        "opencode:",
        "  command: #{yaml_value(opencode_command)}",
        "  agent: #{yaml_value(opencode_agent)}",
        "  model: #{yaml_value(opencode_model)}",
        "  turn_timeout_ms: #{yaml_value(opencode_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(opencode_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(opencode_stall_timeout_ms)}",
        "claude:",
        "  command: #{yaml_value(claude_command)}",
        "  model: #{yaml_value(claude_model)}",
        "  permission_mode: #{yaml_value(claude_permission_mode)}",
        "  turn_timeout_ms: #{yaml_value(claude_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(claude_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(claude_stall_timeout_ms)}",
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        telemetry_yaml(telemetry_enabled, telemetry_otlp_endpoint, telemetry_otlp_protocol, telemetry_include_traces, telemetry_include_metrics, telemetry_include_logs, telemetry_resource_attributes),
        server_yaml(server_port, server_host),
        instance_yaml(instance_name),
        "projects: #{yaml_value(projects)}"
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp instance_yaml(nil), do: nil

  defp instance_yaml(name) do
    [
      "instance:",
      "  name: #{yaml_value(name)}"
    ]
    |> Enum.join("\n")
  end

  defp providers_yaml(nil), do: nil

  defp providers_yaml(openrouter_api_key) do
    [
      "providers:",
      "  openrouter_api_key: #{yaml_value(openrouter_api_key)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp telemetry_yaml(false, _endpoint, _protocol, _traces, _metrics, _logs, _attrs), do: nil

  defp telemetry_yaml(true, endpoint, protocol, traces, metrics, logs, attrs) do
    [
      "telemetry:",
      "  enabled: true",
      "  otlp_endpoint: #{yaml_value(endpoint)}",
      "  otlp_protocol: #{yaml_value(protocol)}",
      "  include_traces: #{yaml_value(traces)}",
      "  include_metrics: #{yaml_value(metrics)}",
      "  include_logs: #{yaml_value(logs)}",
      telemetry_resource_attributes_yaml(attrs)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp telemetry_resource_attributes_yaml(nil), do: nil
  defp telemetry_resource_attributes_yaml(attrs) when map_size(attrs) == 0, do: nil

  defp telemetry_resource_attributes_yaml(attrs) do
    lines =
      attrs
      |> Enum.map(fn {key, value} -> "    #{yaml_value(to_string(key))}: #{yaml_value(to_string(value))}" end)
      |> Enum.join("\n")

    "  resource_attributes:\n" <> lines
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end

  defp project_hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp project_hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms)
  end

  defp project_agent_yaml(nil, nil), do: nil

  defp project_agent_yaml(default_effort, max_turns) do
    [
      "agent:",
      !is_nil(default_effort) && "  default_effort: #{yaml_value(default_effort)}",
      !is_nil(max_turns) && "  max_turns: #{yaml_value(max_turns)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end
end
