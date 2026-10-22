defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."
  @iap_audience "/projects/1234/global/backendServices/5678"

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
      alias SymphonyElixir.ProjectWorkflow
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.SymphonyConfig
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
          iap_audience: 0,
          iap_token: 1,
          iap_token: 2,
          iap_conn: 1,
          iap_account!: 1,
          stop_default_http_server: 0,
          stop_default_orchestrator: 0
        ]

      setup do
        Application.delete_env(:symphony_elixir, :app_mode)
        SymphonyElixir.TestSupport.ensure_default_app!()

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
        SymphonyElixir.TestSupport.ensure_default_app!()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :symphony_config_path)
          Application.delete_env(:symphony_elixir, :startup_mode)
          Application.delete_env(:symphony_elixir, :app_mode)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_comment_ids)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          Application.delete_env(:symphony_elixir, :app_mode)
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

  # Polls instead of sleeping a fixed amount, so a loaded machine does not make
  # a test race the code it is waiting for.
  def wait_until(fun, timeout_ms \\ 1_000) when is_function(fun, 0) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline_ms)
  end

  defp do_wait_until(fun, deadline_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        raise "timed out waiting for condition"
      else
        Process.sleep(5)
        do_wait_until(fun, deadline_ms)
      end
    end
  end

  # Tests share one VM, and a few deliberately stop application children (or
  # used to stop the whole application). Make every test start from the same
  # baseline instead of inheriting whichever child a previous test left down.
  def ensure_default_app! do
    ensure_default_app!(200)
  end

  defp ensure_default_app!(0), do: raise("the Symphony application could not be started")

  defp ensure_default_app!(attempts) do
    supervisor = Process.whereis(SymphonyElixir.Supervisor)
    workflow_store = Process.whereis(SymphonyElixir.WorkflowStore)

    if is_pid(supervisor) and is_pid(workflow_store) do
      :ok
    else
      _ = Application.ensure_all_started(:symphony_elixir)

      if supervisor = Process.whereis(SymphonyElixir.Supervisor) do
        # A previous test may have left the supervisor's child spec running but
        # pointed at a process it started itself and then stopped, or it may be
        # shutting down. Terminating first clears stale state; ignore a
        # supervisor that is already going away and retry below.
        try do
          if is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
            _ = Supervisor.terminate_child(supervisor, SymphonyElixir.WorkflowStore)
            _ = Supervisor.restart_child(supervisor, SymphonyElixir.WorkflowStore)
          end
        catch
          :exit, _reason -> :ok
        end
      end

      Process.sleep(10)
      ensure_default_app!(attempts - 1)
    end
  end

  @doc """
  The IAP audience test configs accept (`server.iap_audiences`).
  """
  def iap_audience, do: @iap_audience

  @doc """
  A signed IAP assertion for `email`, with a test key that `SymphonyElixir.Iap`
  trusts (`:iap_jwks`). `claims` overrides any claim; `nil` drops it.
  """
  def iap_token(email, claims \\ %{}) do
    {public, private} = iap_test_key()
    Application.put_env(:symphony_elixir, :iap_jwks, [iap_jwk(public)])
    now = System.system_time(:second)

    payload =
      %{"iss" => "https://cloud.google.com/iap", "aud" => @iap_audience, "email" => email, "sub" => "accounts.google.com:" <> email, "iat" => now, "exp" => now + 600}
      |> Map.merge(claims)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    signing_input = b64(Jason.encode!(%{"alg" => "ES256", "kid" => "test-key", "typ" => "JWT"})) <> "." <> b64(Jason.encode!(payload))
    der = :crypto.sign(:ecdsa, :sha256, signing_input, [private, :secp256r1])
    signing_input <> "." <> b64(raw_signature(der))
  end

  @doc """
  A conn that came through IAP signed in as `email` (or an account's email).
  """
  def iap_conn(%{email: email}), do: iap_conn(email)
  def iap_conn(email) when is_binary(email), do: Plug.Conn.put_req_header(Phoenix.ConnTest.build_conn(), "x-goog-iap-jwt-assertion", iap_token(email))

  @doc """
  The account for `email`, as on its first IAP visit.
  """
  def iap_account!(email) do
    {:ok, account} = SymphonyElixir.Users.ensure(email)
    account
  end

  defp iap_test_key do
    case :persistent_term.get({__MODULE__, :iap_key}, nil) do
      nil -> tap(:crypto.generate_key(:ecdh, :secp256r1), &:persistent_term.put({__MODULE__, :iap_key}, &1))
      key -> key
    end
  end

  defp iap_jwk(<<4, x::binary-size(32), y::binary-size(32)>>),
    do: %{"kty" => "EC", "crv" => "P-256", "alg" => "ES256", "kid" => "test-key", "x" => b64(x), "y" => b64(y)}

  # DER ECDSA-Sig-Value -> JOSE r || s, 32 bytes each.
  defp raw_signature(der) do
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    pad32(:binary.encode_unsigned(r)) <> pad32(:binary.encode_unsigned(s))
  end

  defp pad32(bytes), do: :binary.copy(<<0>>, 32 - byte_size(bytes)) <> bytes
  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    if Process.whereis(SymphonyElixir.Supervisor) do
      try do
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
      catch
        :exit, _reason -> :ok
      end
    else
      :ok
    end
  end

  def stop_default_orchestrator do
    if Process.whereis(SymphonyElixir.Supervisor) do
      try do
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
      catch
        :exit, _reason -> :ok
      end
    else
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
          tracker_require_label: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          providers_openrouter_api_key: nil,
          accounts_enabled: false,
          accounts_store_root: "~/.symphony/accounts",
          accounts_allow_host_auth_fallback: false,
          accounts_rotation_strategy: "usage_aware_round_robin",
          accounts_max_concurrent_sessions_per_account: 1,
          accounts_exhausted_cooldown_ms: 300_000,
          accounts_daily_token_budget: nil,
          accounts_claude_rate_limit_probe_interval_ms: nil,
          agent_backend: "opencode",
          default_effort: nil,
          agent_launcher: nil,
          agent_runner_command: nil,
          agent_runner_finish_flush_ms: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          tracker_task_timeout_ms: 60_000,
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
          telemetry_otlp_traces_endpoint: nil,
          telemetry_otlp_traces_protocol: nil,
          telemetry_otlp_logs_endpoint: nil,
          telemetry_otlp_logs_protocol: nil,
          telemetry_otlp_metrics_endpoint: nil,
          telemetry_otlp_metrics_protocol: nil,
          telemetry_include_traces: true,
          telemetry_include_metrics: true,
          telemetry_include_logs: true,
          telemetry_log_user_prompts: false,
          telemetry_log_tool_details: false,
          telemetry_resource_attributes: %{},
          server_port: nil,
          server_host: nil,
          server_api_token: nil,
          server_trust_proxy: nil,
          server_iap_audiences: [@iap_audience],
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
    tracker_require_label = Keyword.get(config, :tracker_require_label)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    providers_openrouter_api_key = Keyword.get(config, :providers_openrouter_api_key)
    accounts_enabled = Keyword.get(config, :accounts_enabled)
    accounts_store_root = Keyword.get(config, :accounts_store_root)
    accounts_allow_host_auth_fallback = Keyword.get(config, :accounts_allow_host_auth_fallback)
    accounts_rotation_strategy = Keyword.get(config, :accounts_rotation_strategy)
    accounts_max_concurrent_sessions_per_account = Keyword.get(config, :accounts_max_concurrent_sessions_per_account)
    accounts_exhausted_cooldown_ms = Keyword.get(config, :accounts_exhausted_cooldown_ms)
    accounts_daily_token_budget = Keyword.get(config, :accounts_daily_token_budget)
    accounts_claude_rate_limit_probe_interval_ms = Keyword.get(config, :accounts_claude_rate_limit_probe_interval_ms)
    agent_backend = Keyword.get(config, :agent_backend)
    default_effort = Keyword.get(config, :default_effort)
    agent_launcher = Keyword.get(config, :agent_launcher)
    agent_runner_command = Keyword.get(config, :agent_runner_command)
    agent_runner_finish_flush_ms = Keyword.get(config, :agent_runner_finish_flush_ms)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    tracker_task_timeout_ms = Keyword.get(config, :tracker_task_timeout_ms)
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
    telemetry_otlp_traces_endpoint = Keyword.get(config, :telemetry_otlp_traces_endpoint)
    telemetry_otlp_traces_protocol = Keyword.get(config, :telemetry_otlp_traces_protocol)
    telemetry_otlp_logs_endpoint = Keyword.get(config, :telemetry_otlp_logs_endpoint)
    telemetry_otlp_logs_protocol = Keyword.get(config, :telemetry_otlp_logs_protocol)
    telemetry_otlp_metrics_endpoint = Keyword.get(config, :telemetry_otlp_metrics_endpoint)
    telemetry_otlp_metrics_protocol = Keyword.get(config, :telemetry_otlp_metrics_protocol)
    telemetry_include_traces = Keyword.get(config, :telemetry_include_traces)
    telemetry_include_metrics = Keyword.get(config, :telemetry_include_metrics)
    telemetry_include_logs = Keyword.get(config, :telemetry_include_logs)
    telemetry_log_user_prompts = Keyword.get(config, :telemetry_log_user_prompts)
    telemetry_log_tool_details = Keyword.get(config, :telemetry_log_tool_details)
    telemetry_resource_attributes = Keyword.get(config, :telemetry_resource_attributes)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    server_api_token = Keyword.get(config, :server_api_token)
    server_trust_proxy = Keyword.get(config, :server_trust_proxy)
    server_iap_audiences = Keyword.get(config, :server_iap_audiences)
    git_mirror = Keyword.get(config, :git_mirror)
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
        "  require_label: #{yaml_value(tracker_require_label)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        providers_yaml(providers_openrouter_api_key),
        accounts_yaml(
          accounts_enabled,
          accounts_store_root,
          accounts_allow_host_auth_fallback,
          accounts_rotation_strategy,
          accounts_max_concurrent_sessions_per_account,
          accounts_exhausted_cooldown_ms,
          accounts_daily_token_budget,
          accounts_claude_rate_limit_probe_interval_ms
        ),
        "agent:",
        "  backend: #{yaml_value(agent_backend)}",
        "  default_effort: #{yaml_value(default_effort)}",
        if(is_nil(agent_launcher), do: nil, else: "  launcher: #{yaml_value(agent_launcher)}"),
        if(is_nil(agent_runner_command), do: nil, else: "  runner_command: #{yaml_value(agent_runner_command)}"),
        if(is_nil(agent_runner_finish_flush_ms), do: nil, else: "  runner_finish_flush_ms: #{yaml_value(agent_runner_finish_flush_ms)}"),
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  tracker_task_timeout_ms: #{yaml_value(tracker_task_timeout_ms)}",
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
        telemetry_yaml(telemetry_enabled, %{
          endpoint: telemetry_otlp_endpoint,
          protocol: telemetry_otlp_protocol,
          traces_endpoint: telemetry_otlp_traces_endpoint,
          traces_protocol: telemetry_otlp_traces_protocol,
          logs_endpoint: telemetry_otlp_logs_endpoint,
          logs_protocol: telemetry_otlp_logs_protocol,
          metrics_endpoint: telemetry_otlp_metrics_endpoint,
          metrics_protocol: telemetry_otlp_metrics_protocol,
          traces: telemetry_include_traces,
          metrics: telemetry_include_metrics,
          logs: telemetry_include_logs,
          log_user_prompts: telemetry_log_user_prompts,
          log_tool_details: telemetry_log_tool_details,
          attrs: telemetry_resource_attributes
        }),
        server_yaml(server_port, server_host, server_api_token, server_trust_proxy, server_iap_audiences),
        git_mirror_yaml(git_mirror),
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
          accounts_enabled: false,
          accounts_store_root: "~/.symphony/accounts",
          accounts_allow_host_auth_fallback: false,
          accounts_rotation_strategy: "usage_aware_round_robin",
          accounts_max_concurrent_sessions_per_account: 1,
          accounts_exhausted_cooldown_ms: 300_000,
          accounts_daily_token_budget: nil,
          accounts_claude_rate_limit_probe_interval_ms: nil,
          agent_backend: "codex",
          default_effort: nil,
          agent_launcher: nil,
          agent_runner_command: nil,
          agent_runner_finish_flush_ms: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          tracker_task_timeout_ms: 60_000,
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
          telemetry_otlp_traces_endpoint: nil,
          telemetry_otlp_traces_protocol: nil,
          telemetry_otlp_logs_endpoint: nil,
          telemetry_otlp_logs_protocol: nil,
          telemetry_otlp_metrics_endpoint: nil,
          telemetry_otlp_metrics_protocol: nil,
          telemetry_include_traces: true,
          telemetry_include_metrics: true,
          telemetry_include_logs: true,
          telemetry_log_user_prompts: false,
          telemetry_log_tool_details: false,
          telemetry_resource_attributes: %{},
          server_port: nil,
          server_host: nil,
          server_api_token: nil,
          server_trust_proxy: nil,
          server_iap_audiences: [@iap_audience],
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
    accounts_enabled = Keyword.get(config, :accounts_enabled)
    accounts_store_root = Keyword.get(config, :accounts_store_root)
    accounts_allow_host_auth_fallback = Keyword.get(config, :accounts_allow_host_auth_fallback)
    accounts_rotation_strategy = Keyword.get(config, :accounts_rotation_strategy)
    accounts_max_concurrent_sessions_per_account = Keyword.get(config, :accounts_max_concurrent_sessions_per_account)
    accounts_exhausted_cooldown_ms = Keyword.get(config, :accounts_exhausted_cooldown_ms)
    accounts_daily_token_budget = Keyword.get(config, :accounts_daily_token_budget)
    accounts_claude_rate_limit_probe_interval_ms = Keyword.get(config, :accounts_claude_rate_limit_probe_interval_ms)
    agent_backend = Keyword.get(config, :agent_backend)
    default_effort = Keyword.get(config, :default_effort)
    agent_launcher = Keyword.get(config, :agent_launcher)
    agent_runner_command = Keyword.get(config, :agent_runner_command)
    agent_runner_finish_flush_ms = Keyword.get(config, :agent_runner_finish_flush_ms)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    tracker_task_timeout_ms = Keyword.get(config, :tracker_task_timeout_ms)
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
    telemetry_otlp_traces_endpoint = Keyword.get(config, :telemetry_otlp_traces_endpoint)
    telemetry_otlp_traces_protocol = Keyword.get(config, :telemetry_otlp_traces_protocol)
    telemetry_otlp_logs_endpoint = Keyword.get(config, :telemetry_otlp_logs_endpoint)
    telemetry_otlp_logs_protocol = Keyword.get(config, :telemetry_otlp_logs_protocol)
    telemetry_otlp_metrics_endpoint = Keyword.get(config, :telemetry_otlp_metrics_endpoint)
    telemetry_otlp_metrics_protocol = Keyword.get(config, :telemetry_otlp_metrics_protocol)
    telemetry_include_traces = Keyword.get(config, :telemetry_include_traces)
    telemetry_include_metrics = Keyword.get(config, :telemetry_include_metrics)
    telemetry_include_logs = Keyword.get(config, :telemetry_include_logs)
    telemetry_log_user_prompts = Keyword.get(config, :telemetry_log_user_prompts)
    telemetry_log_tool_details = Keyword.get(config, :telemetry_log_tool_details)
    telemetry_resource_attributes = Keyword.get(config, :telemetry_resource_attributes)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    server_api_token = Keyword.get(config, :server_api_token)
    server_trust_proxy = Keyword.get(config, :server_trust_proxy)
    server_iap_audiences = Keyword.get(config, :server_iap_audiences)
    instance_name = Keyword.get(config, :instance_name)

    projects =
      Keyword.get(config, :projects)
      |> Enum.map(fn project ->
        project
        |> Map.new()
        |> Map.update("workflow", nil, &normalize_project_workflow_path/1)
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
        accounts_yaml(
          accounts_enabled,
          accounts_store_root,
          accounts_allow_host_auth_fallback,
          accounts_rotation_strategy,
          accounts_max_concurrent_sessions_per_account,
          accounts_exhausted_cooldown_ms,
          accounts_daily_token_budget,
          accounts_claude_rate_limit_probe_interval_ms
        ),
        "agent:",
        "  backend: #{yaml_value(agent_backend)}",
        "  default_effort: #{yaml_value(default_effort)}",
        if(is_nil(agent_launcher), do: nil, else: "  launcher: #{yaml_value(agent_launcher)}"),
        if(is_nil(agent_runner_command), do: nil, else: "  runner_command: #{yaml_value(agent_runner_command)}"),
        if(is_nil(agent_runner_finish_flush_ms), do: nil, else: "  runner_finish_flush_ms: #{yaml_value(agent_runner_finish_flush_ms)}"),
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  tracker_task_timeout_ms: #{yaml_value(tracker_task_timeout_ms)}",
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
        telemetry_yaml(telemetry_enabled, %{
          endpoint: telemetry_otlp_endpoint,
          protocol: telemetry_otlp_protocol,
          traces_endpoint: telemetry_otlp_traces_endpoint,
          traces_protocol: telemetry_otlp_traces_protocol,
          logs_endpoint: telemetry_otlp_logs_endpoint,
          logs_protocol: telemetry_otlp_logs_protocol,
          metrics_endpoint: telemetry_otlp_metrics_endpoint,
          metrics_protocol: telemetry_otlp_metrics_protocol,
          traces: telemetry_include_traces,
          metrics: telemetry_include_metrics,
          logs: telemetry_include_logs,
          log_user_prompts: telemetry_log_user_prompts,
          log_tool_details: telemetry_log_tool_details,
          attrs: telemetry_resource_attributes
        }),
        server_yaml(server_port, server_host, server_api_token, server_trust_proxy, server_iap_audiences),
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

  defp git_mirror_yaml(nil), do: nil

  defp git_mirror_yaml(%{} = git_mirror) do
    ["git_mirror:" | Enum.map(git_mirror, fn {key, value} -> "  #{key}: #{yaml_value(value)}" end)]
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

  defp accounts_yaml(
         false,
         "~/.symphony/accounts",
         false,
         "usage_aware_round_robin",
         1,
         300_000,
         nil,
         nil
       ),
       do: nil

  defp accounts_yaml(
         enabled,
         store_root,
         allow_host_auth_fallback,
         rotation_strategy,
         max_concurrent_sessions_per_account,
         exhausted_cooldown_ms,
         daily_token_budget,
         claude_rate_limit_probe_interval_ms
       ) do
    [
      "accounts:",
      "  enabled: #{yaml_value(enabled)}",
      "  store_root: #{yaml_value(store_root)}",
      "  allow_host_auth_fallback: #{yaml_value(allow_host_auth_fallback)}",
      "  rotation_strategy: #{yaml_value(rotation_strategy)}",
      "  max_concurrent_sessions_per_account: #{yaml_value(max_concurrent_sessions_per_account)}",
      "  exhausted_cooldown_ms: #{yaml_value(exhausted_cooldown_ms)}",
      !is_nil(daily_token_budget) && "  daily_token_budget: #{yaml_value(daily_token_budget)}",
      !is_nil(claude_rate_limit_probe_interval_ms) &&
        "  claude_rate_limit_probe_interval_ms: #{yaml_value(claude_rate_limit_probe_interval_ms)}"
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

  defp normalize_project_workflow_path(workflow) do
    if is_binary(workflow) and workflow not in ["", nil] and
         Path.type(workflow) != :absolute and
         not String.starts_with?(workflow, ["./", "../", "~/"]) do
      "./" <> workflow
    else
      workflow
    end
  end

  defp telemetry_yaml(false, _telemetry), do: nil

  defp telemetry_yaml(true, telemetry) do
    [
      "telemetry:",
      "  enabled: true",
      "  otlp_endpoint: #{yaml_value(telemetry.endpoint)}",
      "  otlp_protocol: #{yaml_value(telemetry.protocol)}",
      "  otlp_traces_endpoint: #{yaml_value(telemetry.traces_endpoint)}",
      "  otlp_traces_protocol: #{yaml_value(telemetry.traces_protocol)}",
      "  otlp_logs_endpoint: #{yaml_value(telemetry.logs_endpoint)}",
      "  otlp_logs_protocol: #{yaml_value(telemetry.logs_protocol)}",
      "  otlp_metrics_endpoint: #{yaml_value(telemetry.metrics_endpoint)}",
      "  otlp_metrics_protocol: #{yaml_value(telemetry.metrics_protocol)}",
      "  include_traces: #{yaml_value(telemetry.traces)}",
      "  include_metrics: #{yaml_value(telemetry.metrics)}",
      "  include_logs: #{yaml_value(telemetry.logs)}",
      "  log_user_prompts: #{yaml_value(telemetry.log_user_prompts)}",
      "  log_tool_details: #{yaml_value(telemetry.log_tool_details)}",
      telemetry_resource_attributes_yaml(telemetry.attrs)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp telemetry_resource_attributes_yaml(nil), do: nil
  defp telemetry_resource_attributes_yaml(attrs) when map_size(attrs) == 0, do: nil

  defp telemetry_resource_attributes_yaml(attrs) do
    lines =
      Enum.map_join(attrs, "\n", fn {key, value} -> "    #{yaml_value(to_string(key))}: #{yaml_value(to_string(value))}" end)

    "  resource_attributes:\n" <> lines
  end

  defp server_yaml(nil, nil, nil, nil, _iap_audiences), do: nil

  defp server_yaml(port, host, api_token, trust_proxy, iap_audiences) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}",
      api_token && "  api_token: #{yaml_value(api_token)}",
      trust_proxy && "  trust_proxy: #{yaml_value(trust_proxy)}",
      if(iap_audiences not in [nil, []], do: "  iap_audiences: #{yaml_value(iap_audiences)}")
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
