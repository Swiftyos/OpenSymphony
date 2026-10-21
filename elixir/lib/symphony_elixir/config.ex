defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `symphony.yml` or legacy `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.{SymphonyConfig, Workflow}

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @type opencode_runtime_settings :: %{
          command: String.t(),
          agent: String.t(),
          model: String.t() | nil,
          variant: String.t() | nil,
          turn_timeout_ms: pos_integer(),
          read_timeout_ms: pos_integer(),
          stall_timeout_ms: non_neg_integer()
        }

  @type claude_runtime_settings :: %{
          command: String.t(),
          model: String.t() | nil,
          effort: String.t() | nil,
          permission_mode: String.t(),
          turn_timeout_ms: pos_integer(),
          read_timeout_ms: pos_integer(),
          stall_timeout_ms: non_neg_integer()
        }

  @type accounts_settings :: %{
          enabled: boolean(),
          store_root: Path.t(),
          allow_host_auth_fallback: boolean(),
          rotation_strategy: String.t(),
          max_concurrent_sessions_per_account: pos_integer(),
          exhausted_cooldown_ms: non_neg_integer(),
          daily_token_budget: pos_integer() | nil,
          claude_rate_limit_probe_interval_ms: pos_integer()
        }

  @type linear_project_route :: %{
          slug: String.t(),
          repo: String.t() | nil,
          workflow: String.t() | nil,
          prompt: String.t() | nil,
          hooks: map() | nil,
          backend: String.t() | nil,
          default_branch: String.t() | nil,
          workspace_root: String.t() | nil,
          repos: [map()],
          environment: String.t() | nil
        }

  @typedoc """
  A repo a project's agents can work in: the route's primary `repo`, or one of
  its `repos:`. An issue's home repo is the one its `repo/<name>` label names.
  """
  @type project_repo :: %{
          name: String.t(),
          repo: String.t(),
          default_branch: String.t() | nil,
          description: String.t() | nil,
          primary: boolean()
        }

  @repo_label_group "repo"
  @default_runner_command "setsid {symphony} runner {spec} --i-understand-that-this-will-be-running-without-the-usual-guardrails"

  @type repo_source_kind :: :local_path | :github_slug | :remote_url

  @type repo_source :: %{
          raw: String.t(),
          clone_url: String.t(),
          cache_key: String.t(),
          display: String.t(),
          kind: repo_source_kind()
        }

  @github_repo_pattern ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/

  @spec startup_mode() :: :legacy | :global
  def startup_mode do
    case Application.get_env(:symphony_elixir, :startup_mode) do
      mode when mode in [:legacy, :global] ->
        mode

      _ ->
        if File.regular?(SymphonyConfig.config_file_path()), do: :global, else: :legacy
    end
  end

  @spec global_mode?() :: boolean()
  def global_mode?, do: startup_mode() == :global

  @spec default_prompt_template() :: String.t()
  def default_prompt_template, do: @default_prompt_template

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case startup_mode() do
      :global ->
        case SymphonyConfig.current() do
          {:ok, %{config: config}} when is_map(config) ->
            Schema.parse(config,
              mode: :global,
              base_dir: Path.dirname(SymphonyConfig.config_file_path())
            )

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        case Workflow.current() do
          {:ok, %{config: config}} when is_map(config) ->
            Schema.parse(config,
              mode: :legacy,
              base_dir: Path.dirname(Workflow.workflow_file_path())
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_error(reason)
    end
  end

  @spec validated_settings!() :: Schema.t()
  def validated_settings! do
    case settings() do
      {:ok, %Schema{} = settings} ->
        with :ok <- validate_semantics(settings),
             :ok <- validate_project_route_semantics(settings) do
          settings
        else
          {:error, reason} ->
            raise ArgumentError, message: format_error(reason)
        end

      {:error, reason} ->
        raise ArgumentError, message: format_error(reason)
    end
  end

  @spec format_error(term()) :: String.t()
  def format_error(reason), do: format_config_error(reason)

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec agent_backend() :: String.t()
  def agent_backend, do: settings!().agent.backend

  @doc "The default command template for the process run launcher."
  @spec default_runner_command() :: String.t()
  def default_runner_command, do: @default_runner_command

  @doc """
  How agent runs are started: `:local` in-process, `:process` as separate OS
  processes, or `:kubernetes` as runner pods.
  """
  @spec agent_launcher() :: :local | :process | :kubernetes
  def agent_launcher do
    case settings!().agent.launcher do
      "process" -> :process
      "kubernetes" -> :kubernetes
      _ -> :local
    end
  end

  @doc "The command template used to start a process run."
  @spec agent_runner_command() :: String.t()
  def agent_runner_command, do: settings!().agent.runner_command

  @doc """
  How long a runner keeps retrying to deliver its `finished` event (and the
  events before it) before exiting anyway; one hour by default.
  """
  @spec agent_runner_finish_flush_ms() :: pos_integer()
  def agent_runner_finish_flush_ms, do: settings!().agent.runner_finish_flush_ms

  @spec agent_stall_timeout_ms(String.t() | nil) :: non_neg_integer()
  def agent_stall_timeout_ms(backend \\ nil) do
    settings = settings!()

    case backend || settings.agent.backend do
      "opencode" -> settings.opencode.stall_timeout_ms
      "claude" -> settings.claude.stall_timeout_ms
      _ -> settings.codex.stall_timeout_ms
    end
  end

  @spec codex_command(String.t() | nil) :: String.t()
  def codex_command(effort \\ nil) do
    command = settings!().codex.command

    case Schema.normalize_optional_effort(effort) do
      nil -> command
      effort when effort in ["max", "xhigh"] -> with_codex_config(command, "model_reasoning_effort=xhigh")
      normalized_effort -> with_codex_config(command, "model_reasoning_effort=" <> normalized_effort)
    end
  end

  # A `-c` given after `app-server` discards every `-c` given before it, so the
  # override goes where the command's own settings are: after `app-server` when
  # they're there (or there are none), otherwise just before it. `setting` is
  # inserted verbatim, so callers shell-quote it when it isn't a bare word.
  @spec with_codex_config(String.t(), String.t()) :: String.t()
  def with_codex_config(command, setting) do
    case String.split(command, ~r/\sapp-server\b/, parts: 2) do
      [before, rest] ->
        if Regex.match?(~r/(^|\s)(-c|--config)(\s|=)/, before) and not Regex.match?(~r/(^|\s)(-c|--config)(\s|=)/, rest),
          do: before <> " -c " <> setting <> " app-server" <> rest,
          else: command <> " -c " <> setting

      [_whole] ->
        command <> " -c " <> setting
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    if global_mode?() do
      @default_prompt_template
    else
      current_workflow_prompt()
    end
  end

  defp current_workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec instance_name() :: String.t() | nil
  def instance_name do
    settings!().instance.name
  end

  @doc """
  The configured brand logo's path (`instance.logo`, `~` expanded), or nil.
  """
  @spec instance_logo() :: Path.t() | nil
  def instance_logo do
    case settings() do
      {:ok, %{instance: %{logo: logo}}} when is_binary(logo) -> Path.expand(logo)
      _ -> nil
    end
  end

  @spec log_dir() :: Path.t() | nil
  def log_dir do
    case settings() do
      {:ok, %{log: %{dir: dir}}} when is_binary(dir) and dir != "" -> dir
      _ -> nil
    end
  end

  @spec log_file_name() :: String.t()
  def log_file_name do
    case settings() do
      {:ok, %{log: %{file_name: file_name}}} when is_binary(file_name) and file_name != "" ->
        file_name

      _ ->
        "symphony.log"
    end
  end

  @spec log_max_bytes() :: pos_integer() | nil
  def log_max_bytes do
    case settings() do
      {:ok, %{log: %{max_bytes: bytes}}} when is_integer(bytes) and bytes > 0 -> bytes
      _ -> nil
    end
  end

  @spec log_max_files() :: pos_integer() | nil
  def log_max_files do
    case settings() do
      {:ok, %{log: %{max_files: files}}} when is_integer(files) and files > 0 -> files
      _ -> nil
    end
  end

  @doc """
  The ClickHouse source for dashboard metrics and traces (`observability.clickhouse`),
  or nil when no URL is configured or the config does not load.
  """
  @spec observability_clickhouse() :: map() | nil
  def observability_clickhouse do
    case settings() do
      {:ok, %{observability: %{clickhouse: %{url: url} = clickhouse} = observability}} when is_binary(url) ->
        %{
          url: url,
          user: clickhouse.user,
          password: clickhouse.password,
          database: clickhouse.database || "otel",
          timeout_ms: observability.timeout_ms
        }

      _ ->
        nil
    end
  end

  @doc """
  The Langfuse source for dashboard traces (`observability.langfuse`), or nil
  unless the URL and both keys are configured.
  """
  @spec observability_langfuse() :: map() | nil
  def observability_langfuse do
    case settings() do
      {:ok, %{observability: observability}} -> langfuse_source(observability)
      _ -> nil
    end
  end

  defp langfuse_source(%{langfuse: %{url: url, public_key: public, secret_key: secret} = langfuse} = observability)
       when is_binary(url) and is_binary(public) and is_binary(secret) do
    %{
      url: url,
      public_key: public,
      secret_key: secret,
      public_url: langfuse.public_url,
      timeout_ms: observability.timeout_ms
    }
  end

  defp langfuse_source(_observability), do: nil

  @doc "How long dashboard metrics and traces are cached, in milliseconds."
  @spec observability_cache_ttl_ms() :: non_neg_integer()
  def observability_cache_ttl_ms do
    case settings() do
      {:ok, %{observability: %{cache_ttl_ms: ttl}}} when is_integer(ttl) and ttl >= 0 -> ttl
      _ -> 30_000
    end
  end

  @doc "How often the capacity sampler measures running agents, in milliseconds. 0 disables it."
  @spec capacity_sample_interval_ms() :: non_neg_integer()
  def capacity_sample_interval_ms do
    settings!().capacity.sample_interval_ms
  end

  @spec telemetry_enabled?() :: boolean()
  def telemetry_enabled? do
    settings!().telemetry.enabled
  end

  @spec telemetry_otlp_endpoint() :: String.t() | nil
  def telemetry_otlp_endpoint do
    normalize_optional_string(settings!().telemetry.otlp_endpoint)
  end

  @spec telemetry_otlp_protocol() :: String.t()
  def telemetry_otlp_protocol do
    settings!().telemetry.otlp_protocol
  end

  @spec telemetry_otlp_traces_endpoint() :: String.t() | nil
  def telemetry_otlp_traces_endpoint do
    normalize_optional_string(settings!().telemetry.otlp_traces_endpoint)
  end

  @spec telemetry_otlp_traces_protocol() :: String.t() | nil
  def telemetry_otlp_traces_protocol do
    normalize_optional_string(settings!().telemetry.otlp_traces_protocol)
  end

  @spec telemetry_otlp_logs_endpoint() :: String.t() | nil
  def telemetry_otlp_logs_endpoint do
    normalize_optional_string(settings!().telemetry.otlp_logs_endpoint)
  end

  @spec telemetry_otlp_logs_protocol() :: String.t() | nil
  def telemetry_otlp_logs_protocol do
    normalize_optional_string(settings!().telemetry.otlp_logs_protocol)
  end

  @spec telemetry_otlp_metrics_endpoint() :: String.t() | nil
  def telemetry_otlp_metrics_endpoint do
    normalize_optional_string(settings!().telemetry.otlp_metrics_endpoint)
  end

  @spec telemetry_otlp_metrics_protocol() :: String.t() | nil
  def telemetry_otlp_metrics_protocol do
    normalize_optional_string(settings!().telemetry.otlp_metrics_protocol)
  end

  @spec telemetry_include_traces?() :: boolean()
  def telemetry_include_traces? do
    settings!().telemetry.include_traces
  end

  @spec telemetry_include_metrics?() :: boolean()
  def telemetry_include_metrics? do
    settings!().telemetry.include_metrics
  end

  @spec telemetry_include_logs?() :: boolean()
  def telemetry_include_logs? do
    settings!().telemetry.include_logs
  end

  @spec telemetry_resource_attributes() :: map()
  def telemetry_resource_attributes do
    settings!().telemetry.resource_attributes
  end

  @spec telemetry_issue_resource_attributes(map(), String.t() | nil, map() | nil) :: String.t() | nil
  def telemetry_issue_resource_attributes(issue, backend \\ nil, account \\ nil) when is_map(issue) do
    base_attrs = telemetry_resource_attributes()

    attrs =
      base_attrs
      |> maybe_put_resource("linear.issue.id", Map.get(issue, :id) || Map.get(issue, "id"))
      |> maybe_put_resource("linear.issue.identifier", Map.get(issue, :identifier) || Map.get(issue, "identifier"))
      |> maybe_put_resource("symphony.backend", backend)
      |> maybe_put_resource("symphony.instance", instance_name())
      |> maybe_put_resource("symphony.account.id", account_value(account, :id))
      |> maybe_put_resource("symphony.account.email", account_value(account, :email))
      |> maybe_put_resource("symphony.account.backend", account_value(account, :backend))
      |> maybe_put_resource("symphony.account.state", account_value(account, :state))
      |> maybe_put_resource("symphony.account.credential_kind", account_value(account, :credential_kind))

    if map_size(attrs) == 0 do
      nil
    else
      Enum.map_join(attrs, ",", fn {key, value} ->
        "#{percent_encode_resource_key(key)}=#{percent_encode_resource_value(value)}"
      end)
    end
  end

  defp maybe_put_resource(attrs, _key, nil), do: attrs
  defp maybe_put_resource(attrs, _key, ""), do: attrs
  defp maybe_put_resource(attrs, key, value), do: Map.put(attrs, key, to_string(value))

  defp account_value(nil, _key), do: nil

  defp account_value(account, key) when is_map(account) do
    Map.get(account, key) || Map.get(account, Atom.to_string(key))
  end

  defp percent_encode_resource_key(key) do
    key
    |> to_string()
    |> URI.encode(&resource_char?/1)
  end

  defp percent_encode_resource_value(value) do
    value
    |> to_string()
    |> URI.encode(&resource_char?/1)
  end

  defp resource_char?(c) do
    c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c"-_.~/"
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @spec accounts_settings() :: accounts_settings()
  def accounts_settings do
    accounts = settings!().accounts

    %{
      enabled: accounts.enabled,
      store_root: accounts.store_root,
      allow_host_auth_fallback: accounts.allow_host_auth_fallback,
      rotation_strategy: accounts.rotation_strategy,
      max_concurrent_sessions_per_account: accounts.max_concurrent_sessions_per_account,
      exhausted_cooldown_ms: accounts.exhausted_cooldown_ms,
      daily_token_budget: accounts.daily_token_budget,
      claude_rate_limit_probe_interval_ms: accounts.claude_rate_limit_probe_interval_ms
    }
  end

  @spec accounts_enabled?() :: boolean()
  def accounts_enabled?, do: settings!().accounts.enabled

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings(),
         :ok <- validate_semantics(settings) do
      validate_project_route_semantics(settings)
    end
  end

  @spec linear_project_routes() :: [linear_project_route()]
  def linear_project_routes, do: linear_project_routes(settings!())

  @spec linear_project_routes(Schema.t()) :: [linear_project_route()]
  def linear_project_routes(%Schema{} = settings) do
    routes =
      settings.tracker.projects
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1.slug) and String.trim(&1.slug) != ""))
      |> with_stored_routes()

    case routes do
      [] ->
        case settings.tracker.project_slug do
          project_slug when is_binary(project_slug) ->
            [
              %{
                slug: project_slug,
                repo: nil,
                workflow: nil,
                backend: nil,
                workspace_root: nil,
                repos: [],
                environment: nil
              }
            ]

          _ ->
            []
        end

      _ ->
        routes
    end
  end

  # Multi-project mode also listens to the projects added at runtime (MCP,
  # `SymphonyElixir.ProjectRoutes`); a project in the file wins over a stored one.
  defp with_stored_routes(routes) do
    if startup_mode() == :global do
      file_slugs = MapSet.new(routes, & &1.slug)
      routes ++ Enum.reject(SymphonyElixir.ProjectRoutes.tracker_projects(), &MapSet.member?(file_slugs, &1.slug))
    else
      routes
    end
  end

  @doc """
  The catalog environment a team defaults to, from the platform `teams:` block.
  Team keys are matched case-insensitively (`PAY` / `pay`).
  """
  @spec team_environment(String.t() | nil) :: String.t() | nil
  def team_environment(team), do: team_environment(team, settings!())

  @spec team_environment(String.t() | nil, Schema.t()) :: String.t() | nil
  def team_environment(team, %Schema{} = settings) when is_binary(team) do
    key = team |> String.trim() |> String.upcase()

    settings.teams
    |> Enum.to_list()
    |> Enum.find_value(fn {candidate, config} ->
      if is_binary(candidate) and String.upcase(String.trim(candidate)) == key do
        environment_from_team_config(config)
      end
    end)
  end

  def team_environment(_team, %Schema{}), do: nil

  defp environment_from_team_config(%{environment: environment}) when is_binary(environment),
    do: normalize_route_environment(environment)

  defp environment_from_team_config(%{"environment" => environment}) when is_binary(environment),
    do: normalize_route_environment(environment)

  defp environment_from_team_config(_config), do: nil

  defp normalize_route_environment(environment) do
    case String.trim(environment) do
      "" -> nil
      value -> value
    end
  end

  @spec workspace_roots() :: [Path.t()]
  def workspace_roots, do: workspace_roots(settings!())

  @spec workspace_roots(Schema.t()) :: [Path.t()]
  def workspace_roots(%Schema{} = settings) do
    [settings.workspace.root | Enum.map(linear_project_routes(settings), & &1.workspace_root)]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  @spec project_workspace_roots() :: [Path.t()]
  def project_workspace_roots, do: project_workspace_roots(settings!())

  @spec project_workspace_roots(Schema.t()) :: [Path.t()]
  def project_workspace_roots(%Schema{} = settings) do
    routes = linear_project_routes(settings)

    case routes do
      [] ->
        [settings.workspace.root]

      _ ->
        route_count = length(routes)

        routes
        |> Enum.map(&workspace_root_for_route(&1, settings, route_count))
        |> Enum.uniq()
    end
  end

  @spec workspace_root_for_issue(map() | String.t() | nil) :: Path.t()
  def workspace_root_for_issue(issue_or_identifier), do: workspace_root_for_issue(issue_or_identifier, settings!())

  @spec workspace_root_for_issue(map() | String.t() | nil, Schema.t()) :: Path.t()
  def workspace_root_for_issue(issue_or_identifier, %Schema{} = settings) do
    routes = linear_project_routes(settings)
    route_count = length(routes)

    case linear_project_route(issue_or_identifier, settings) do
      %{workspace_root: workspace_root} when is_binary(workspace_root) and workspace_root != "" ->
        workspace_root

      %{slug: slug} when is_binary(slug) and route_count > 1 ->
        Path.join(settings.workspace.root, safe_workspace_segment(slug))

      _ ->
        settings.workspace.root
    end
  end

  @spec project_repo_for_issue(map() | String.t() | nil) :: String.t() | nil
  def project_repo_for_issue(issue_or_identifier), do: project_repo_for_issue(issue_or_identifier, settings!())

  @spec project_repo_for_issue(map() | String.t() | nil, Schema.t()) :: String.t() | nil
  def project_repo_for_issue(issue_or_identifier, %Schema{} = settings) do
    case issue_repo(issue_or_identifier, settings) do
      %{repo: repo} -> repo
      nil -> nil
    end
  end

  @doc """
  The repos a project route's agents can work in, primary first. The primary is
  named after its repo (`acme/payments-api` -> `payments-api`).
  """
  @spec project_repos(map() | nil) :: [project_repo()]
  def project_repos(%{repo: repo} = route) when is_binary(repo) and repo != "" do
    primary = %{name: repo_name(repo), repo: repo, default_branch: Map.get(route, :default_branch), description: nil, primary: true}

    extra =
      for %{name: name, repo: extra_repo} = entry <- List.wrap(Map.get(route, :repos)), is_binary(name) and is_binary(extra_repo) do
        %{name: name, repo: extra_repo, default_branch: Map.get(entry, :default_branch), description: Map.get(entry, :description), primary: false}
      end

    [primary | extra]
  end

  def project_repos(_route), do: []

  @doc """
  The repo an issue's work happens in: the one its `repo/<name>` label names,
  else the project's primary repo. Nil when the project has no repo.
  """
  @spec issue_repo(map() | String.t() | nil, Schema.t()) :: project_repo() | nil
  def issue_repo(issue_or_identifier, %Schema{} = settings) do
    issue_repo_for_route(issue_or_identifier, linear_project_route(issue_or_identifier, settings))
  end

  @doc """
  The issue's home repo within an already resolved project route (as a run
  spec carries it): the repo its `repo/<name>` label names, else the primary.
  """
  @spec issue_repo_for_route(map() | String.t() | nil, map() | nil) :: project_repo() | nil
  def issue_repo_for_route(issue_or_identifier, route) do
    repos = project_repos(route)
    wanted = issue_repo_label_name(issue_or_identifier)

    Enum.find(repos, &(&1.name == wanted)) || List.first(repos)
  end

  @doc """
  The Linear label group that picks an issue's repo (`repo/<name>`).
  """
  @spec repo_label_group() :: String.t()
  def repo_label_group, do: @repo_label_group

  @doc """
  The label that sends an issue to the named repo.
  """
  @spec repo_label(String.t()) :: String.t()
  def repo_label(name) when is_binary(name), do: @repo_label_group <> "/" <> name

  @doc """
  The short name of a repo: its last path segment, lowercased, without `.git`.
  """
  @spec repo_name(String.t()) :: String.t()
  def repo_name(repo) when is_binary(repo) do
    repo
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.split(["/", ":"])
    |> List.last()
    |> String.replace_suffix(".git", "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "repo"
      name -> name
    end
  end

  defp issue_repo_label_name(issue) do
    prefix = @repo_label_group <> "/"

    issue
    |> issue_labels()
    |> Enum.find_value(fn label ->
      label = String.downcase(label)
      if String.starts_with?(label, prefix), do: String.replace_prefix(label, prefix, "")
    end)
  end

  defp issue_labels(%{labels: labels}) when is_list(labels), do: Enum.filter(labels, &is_binary/1)
  defp issue_labels(%{"labels" => labels}) when is_list(labels), do: Enum.filter(labels, &is_binary/1)
  defp issue_labels(_issue), do: []

  @spec project_repo_source_for_issue(map() | String.t() | nil) :: repo_source() | nil
  def project_repo_source_for_issue(issue_or_identifier),
    do: project_repo_source_for_issue(issue_or_identifier, settings!())

  @spec project_repo_source_for_issue(map() | String.t() | nil, Schema.t()) :: repo_source() | nil
  def project_repo_source_for_issue(issue_or_identifier, %Schema{} = settings) do
    issue_or_identifier
    |> project_repo_for_issue(settings)
    |> case do
      repo when is_binary(repo) -> repo_source(repo)
      _ -> nil
    end
  end

  @spec project_default_branch_for_issue(map() | String.t() | nil) :: String.t() | nil
  def project_default_branch_for_issue(issue_or_identifier),
    do: project_default_branch_for_issue(issue_or_identifier, settings!())

  @spec project_default_branch_for_issue(map() | String.t() | nil, Schema.t()) :: String.t() | nil
  def project_default_branch_for_issue(issue_or_identifier, %Schema{} = settings) do
    case issue_repo(issue_or_identifier, settings) do
      %{default_branch: default_branch} when is_binary(default_branch) and default_branch != "" ->
        default_branch

      _ ->
        nil
    end
  end

  @spec repo_source(String.t()) :: repo_source()
  def repo_source(repo) when is_binary(repo) do
    normalized_repo = String.trim(repo)

    cond do
      local_repo_path?(normalized_repo) ->
        build_repo_source(:local_path, normalized_repo, normalized_repo, normalized_repo)

      github_repo_slug?(normalized_repo) ->
        build_repo_source(
          :github_slug,
          normalized_repo,
          "https://github.com/#{normalized_repo}.git",
          normalized_repo
        )

      true ->
        build_repo_source(:remote_url, normalized_repo, normalized_repo, normalized_repo)
    end
  end

  @spec resolve_project_workflow_path(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def resolve_project_workflow_path(repo_root, workflow_ref)
      when is_binary(repo_root) and is_binary(workflow_ref) do
    normalized_workflow_ref = String.trim(workflow_ref)

    cond do
      normalized_workflow_ref == "" ->
        {:error, {:invalid_workflow_config, "project workflow path must not be blank"}}

      not repo_relative_workflow_path?(normalized_workflow_ref) ->
        {:error, {:invalid_workflow_config, "project workflow path must be relative to the repo root: #{workflow_ref}"}}

      true ->
        expanded_repo_root = Path.expand(repo_root)
        resolved_path = Path.expand(normalized_workflow_ref, expanded_repo_root)

        if path_within_root_or_equal?(resolved_path, expanded_repo_root) do
          {:ok, resolved_path}
        else
          {:error, {:invalid_workflow_config, "project workflow path escapes the repo root: #{workflow_ref}"}}
        end
    end
  end

  @spec linear_project_route(map() | String.t() | nil) :: linear_project_route() | nil
  def linear_project_route(issue_or_identifier), do: linear_project_route(issue_or_identifier, settings!())

  @spec linear_project_route(map() | String.t() | nil, Schema.t()) :: linear_project_route() | nil
  def linear_project_route(issue_or_identifier, %Schema{} = settings) do
    project_slug = issue_project_slug(issue_or_identifier)

    Enum.find(linear_project_routes(settings), fn route ->
      route_matches_project_slug?(route, project_slug)
    end)
  end

  @spec workspace_root_for_route(linear_project_route(), Schema.t()) :: Path.t()
  def workspace_root_for_route(route, %Schema{} = settings) when is_map(route) do
    workspace_root_for_route(route, settings, length(linear_project_routes(settings)))
  end

  @type workspace_path_error ::
          {:workspace_root, Path.t(), Path.t()}
          | {:symlink_escape, Path.t(), Path.t()}
          | {:outside_workspace_root, Path.t(), Path.t() | [Path.t()]}
          | {:path_unreadable, Path.t(), term()}

  @spec validate_workspace_path(Path.t()) :: {:ok, Path.t()} | {:error, workspace_path_error()}
  def validate_workspace_path(workspace), do: validate_workspace_path(workspace, settings!())

  @spec validate_workspace_path(Path.t(), Schema.t()) ::
          {:ok, Path.t()} | {:error, workspace_path_error()}
  def validate_workspace_path(workspace, %Schema{} = settings) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_roots = Enum.map(workspace_roots(settings), &Path.expand/1)

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_roots} <- canonicalize_workspace_roots(expanded_roots) do
      cond do
        matching_root = Enum.find(canonical_roots, &(canonical_workspace == &1)) ->
          {:error, {:workspace_root, canonical_workspace, matching_root}}

        Enum.any?(canonical_roots, &path_within_root?(canonical_workspace, &1)) ->
          {:ok, canonical_workspace}

        symlink_root =
            Enum.zip(expanded_roots, canonical_roots)
            |> Enum.find_value(fn {expanded_root, canonical_root} ->
              if path_within_root?(expanded_workspace, expanded_root) and
                   not path_within_root?(canonical_workspace, canonical_root) and
                     canonical_workspace != canonical_root do
                canonical_root
              end
            end) ->
          {:error, {:symlink_escape, expanded_workspace, symlink_root}}

        true ->
          {:error, {:outside_workspace_root, canonical_workspace, root_error_context(canonical_roots)}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:path_unreadable, path, reason}}
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  @spec opencode_runtime_settings(keyword()) :: {:ok, opencode_runtime_settings()} | {:error, term()}
  def opencode_runtime_settings(opts \\ []) do
    with {:ok, settings} <- settings() do
      {:ok,
       %{
         command: settings.opencode.command,
         agent: settings.opencode.agent,
         model: settings.opencode.model,
         variant: Schema.normalize_optional_effort(Keyword.get(opts, :variant)),
         turn_timeout_ms: settings.opencode.turn_timeout_ms,
         read_timeout_ms: settings.opencode.read_timeout_ms,
         stall_timeout_ms: settings.opencode.stall_timeout_ms
       }}
    end
  end

  @spec claude_runtime_settings(keyword()) :: {:ok, claude_runtime_settings()} | {:error, term()}
  def claude_runtime_settings(opts \\ []) do
    with {:ok, settings} <- settings() do
      {:ok,
       %{
         command: settings.claude.command,
         model: settings.claude.model,
         effort: Schema.normalize_optional_effort(Keyword.get(opts, :effort)),
         permission_mode: settings.claude.permission_mode,
         turn_timeout_ms: settings.claude.turn_timeout_ms,
         read_timeout_ms: settings.claude.read_timeout_ms,
         stall_timeout_ms: settings.claude.stall_timeout_ms
       }}
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and linear_project_routes(settings) == [] ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp validate_project_route_semantics(%Schema{} = settings) do
    if global_mode?() do
      validate_global_project_routes(linear_project_routes(settings))
    else
      :ok
    end
  end

  defp validate_global_project_routes(routes) do
    Enum.reduce_while(routes, :ok, fn route, :ok ->
      case validate_global_project_route(route) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # `workflow` (a repo-local WORKFLOW.md) is optional: without it the project
  # runs on Symphony's own config and agent prompt.
  defp validate_global_project_route(%{slug: slug, workflow: workflow_path} = route) do
    prompt = Map.get(route, :prompt)
    error = &{:error, {:invalid_workflow_config, "projects #{inspect(slug)} " <> &1}}

    cond do
      not (is_binary(route.repo) and String.trim(route.repo) != "") ->
        error.("must set an explicit repo")

      local_repo_path?(route.repo) and not File.exists?(route.repo) ->
        error.("repo path does not exist: #{route.repo}")

      missing_file?(prompt) ->
        error.("prompt file does not exist: #{prompt}")

      not optional_repo_relative_path?(workflow_path) ->
        error.("workflow must be relative to the repo root: #{workflow_path}")

      true ->
        validate_project_repos(slug, project_repos(route))
    end
  end

  defp missing_file?(nil), do: false
  defp missing_file?(path), do: not File.regular?(path)

  defp optional_repo_relative_path?(nil), do: true
  defp optional_repo_relative_path?(path), do: repo_relative_workflow_path?(path)

  defp validate_project_repos(slug, repos) do
    duplicate =
      repos
      |> Enum.frequencies_by(& &1.name)
      |> Enum.find_value(fn {name, count} -> if count > 1, do: name end)

    missing = Enum.find(repos, &(not &1.primary and local_repo_path?(&1.repo) and not File.exists?(&1.repo)))

    cond do
      duplicate ->
        {:error, {:invalid_workflow_config, "projects #{inspect(slug)} has two repos named #{inspect(duplicate)} (the primary repo is named after its last path segment)"}}

      missing ->
        {:error, {:invalid_workflow_config, "projects #{inspect(slug)} repo #{inspect(missing.name)} path does not exist: #{missing.repo}"}}

      true ->
        :ok
    end
  end

  defp format_config_error(:missing_linear_api_token) do
    "Linear API token missing in #{config_source_name()}. Export `LINEAR_API_KEY` in the shell where Symphony starts or set `tracker.api_key` explicitly."
  end

  defp format_config_error(:missing_linear_project_slug) do
    "Linear project slug missing in #{config_source_name()}"
  end

  defp format_config_error(:missing_tracker_kind) do
    "Tracker kind missing in #{config_source_name()}"
  end

  defp format_config_error({:unsupported_tracker_kind, kind}) do
    "Unsupported tracker kind in #{config_source_name()}: #{inspect(kind)}"
  end

  defp format_config_error({:invalid_workflow_config, message}) do
    "Invalid #{config_source_name()} config: #{message}"
  end

  defp format_config_error({:missing_workflow_file, path, raw_reason}) do
    "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"
  end

  defp format_config_error({:missing_symphony_config_file, path, raw_reason}) do
    "Missing symphony.yml at #{path}: #{inspect(raw_reason)}"
  end

  defp format_config_error({:workflow_parse_error, raw_reason}) do
    "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"
  end

  defp format_config_error(:workflow_front_matter_not_a_map) do
    "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"
  end

  defp format_config_error({:symphony_config_parse_error, raw_reason}) do
    "Failed to parse symphony.yml: #{inspect(raw_reason)}"
  end

  defp format_config_error(:symphony_config_not_a_map) do
    "Failed to parse symphony.yml: config must decode to a map"
  end

  defp format_config_error(other) do
    "Invalid #{config_source_name()} config: #{inspect(other)}"
  end

  defp issue_project_slug(%{project_slug: project_slug}) when is_binary(project_slug), do: project_slug
  defp issue_project_slug(%{"project_slug" => project_slug}) when is_binary(project_slug), do: project_slug
  defp issue_project_slug(_issue_or_identifier), do: nil

  defp route_matches_project_slug?(%{slug: route_slug}, project_slug)
       when is_binary(route_slug) and is_binary(project_slug) do
    normalize_linear_project_slug(route_slug) == normalize_linear_project_slug(project_slug)
  end

  defp route_matches_project_slug?(_route, _project_slug), do: false

  defp normalize_linear_project_slug(value) when is_binary(value) do
    normalized_value = String.downcase(String.trim(value))

    case Regex.run(~r/(?:^|[-_])([0-9a-f]{12,})$/, normalized_value, capture: :all_but_first) do
      [slug_id] -> slug_id
      _ -> normalized_value
    end
  end

  defp workspace_root_for_route(route, settings, route_count) do
    case route.workspace_root do
      workspace_root when is_binary(workspace_root) and workspace_root != "" ->
        workspace_root

      _ when route_count > 1 ->
        Path.join(settings.workspace.root, safe_workspace_segment(route.slug))

      _ ->
        settings.workspace.root
    end
  end

  defp safe_workspace_segment(segment) when is_binary(segment) do
    String.replace(segment, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp path_within_root?(path, root)
       when is_binary(path) and is_binary(root) and path != root do
    String.starts_with?(path <> "/", root <> "/")
  end

  defp path_within_root?(_path, _root), do: false

  defp path_within_root_or_equal?(path, root)
       when is_binary(path) and is_binary(root) do
    path == root or path_within_root?(path, root)
  end

  defp path_within_root_or_equal?(_path, _root), do: false

  defp canonicalize_workspace_roots(expanded_roots) when is_list(expanded_roots) do
    Enum.reduce_while(expanded_roots, {:ok, []}, fn root, {:ok, acc} ->
      case PathSafety.canonicalize(root) do
        {:ok, canonical_root} ->
          {:cont, {:ok, [canonical_root | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, roots} -> {:ok, roots |> Enum.reverse() |> Enum.uniq()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp root_error_context([root]), do: root
  defp root_error_context(roots), do: roots

  defp config_source_name do
    if global_mode?(), do: "symphony.yml", else: "WORKFLOW.md"
  end

  defp build_repo_source(kind, raw, clone_url, display) do
    %{
      raw: raw,
      clone_url: clone_url,
      cache_key: repo_cache_key(kind, clone_url),
      display: display,
      kind: kind
    }
  end

  defp repo_cache_key(kind, clone_url) do
    prefix =
      case kind do
        :local_path -> Path.basename(clone_url)
        :github_slug -> clone_url |> String.replace_prefix("https://github.com/", "") |> String.replace_suffix(".git", "")
        :remote_url -> clone_url
      end
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
      |> String.trim("_")
      |> case do
        "" -> "repo"
        value -> String.slice(value, 0, 64)
      end

    digest =
      :crypto.hash(:sha256, clone_url)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    prefix <> "-" <> digest
  end

  defp github_repo_slug?(value) when is_binary(value), do: String.match?(value, @github_repo_pattern)

  defp repo_relative_workflow_path?(value) when is_binary(value) do
    trimmed_value = String.trim(value)
    trimmed_value != "" and Path.type(trimmed_value) == :relative and not String.starts_with?(trimmed_value, "~")
  end

  defp repo_relative_workflow_path?(_value), do: false

  defp local_repo_path?(value) when is_binary(value) do
    value in [".", "..", "~"] or String.starts_with?(value, ["./", "../", "/", "~/"])
  end

  defp local_repo_path?(_value), do: false
end
