defmodule SymphonyElixir.IssueConfig do
  @moduledoc """
  Resolves the effective workflow and per-issue settings for a Linear issue.
  """

  alias SymphonyElixir.{AgentPrompt, Config}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Environment
  alias SymphonyElixir.ProjectWorkflow
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workspace

  defstruct [
    :mode,
    :project_route,
    :workflow_path,
    :workflow,
    :settings,
    :environment,
    :prompt_template
  ]

  @type t :: %__MODULE__{
          mode: :legacy | :global,
          project_route: map() | nil,
          workflow_path: Path.t() | nil,
          workflow: map() | nil,
          settings: Schema.t(),
          environment: Environment.t() | nil,
          prompt_template: String.t()
        }

  @spec resolve(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(issue, opts \\ []) when is_map(issue) do
    settings = Keyword.get(opts, :settings, Config.settings!())
    project_route = Keyword.get(opts, :project_route)
    workspace_root = Keyword.get(opts, :workspace_root)

    resolved =
      case Config.startup_mode() do
        :global -> resolve_global(issue, settings, project_route, workspace_root)
        _ -> resolve_legacy(issue, settings, project_route)
      end

    with {:ok, %__MODULE__{} = config} <- resolved,
         :ok <- check_repo_label(issue, config.project_route) do
      {:ok, config}
    end
  end

  # An issue whose `repo/<name>` label names no repo of its project (or that has
  # two) isn't worked anywhere: guessing the primary would put the work in a repo
  # nobody asked for. `SymphonyElixir.RepoLabelCheck` tells the issue why.
  defp check_repo_label(issue, project_route) do
    case Config.check_issue_repo(issue, project_route) do
      {:ok, _repo} -> :ok
      {:error, reason} -> {:error, {:repo_label_invalid, issue_identifier(issue), reason}}
    end
  end

  # A project with a repo-local WORKFLOW.md takes its prompt and agent settings
  # from it; one without takes them from Symphony (symphony.yml and the built-in
  # agent prompt). The project's own `hooks` and `prompt` win either way.
  defp resolve_global(issue, %Schema{} = settings, supplied_route, workspace_root) do
    case supplied_route || Config.linear_project_route(issue, settings) do
      %{workflow: workflow_ref} = project_route when is_binary(workflow_ref) and workflow_ref != "" ->
        with {:ok, repo_root} <-
               Workspace.ensure_local_repo_cache(project_route, settings, workspace_root: workspace_root),
             {:ok, workflow_path} <- Config.resolve_project_workflow_path(repo_root, workflow_ref),
             {:ok, workflow} <- ProjectWorkflow.load(workflow_path),
             {:ok, prompt} <- project_prompt(project_route, prompt_template(workflow.prompt_template)),
             {:ok, environment} <- resolve_environment(issue, settings, project_route, repo_root) do
          effective_settings =
            settings
            |> merge_settings(project_route, workflow)
            |> merge_project_hooks(project_route)
            |> put_environment(environment)

          {:ok,
           %__MODULE__{
             mode: :global,
             project_route: project_route,
             workflow_path: workflow_path,
             workflow: workflow,
             settings: effective_settings,
             environment: environment,
             prompt_template: prompt
           }}
        end

      %{slug: _slug} = project_route ->
        with {:ok, prompt} <- project_prompt(project_route, AgentPrompt.template()),
             {:ok, environment} <- resolve_environment(issue, settings, project_route, nil) do
          {:ok,
           %__MODULE__{
             mode: :global,
             project_route: project_route,
             workflow_path: nil,
             workflow: nil,
             settings:
               settings
               |> merge_route_backend(project_route)
               |> merge_project_hooks(project_route)
               |> put_environment(environment),
             environment: environment,
             prompt_template: prompt
           }}
        end

      nil ->
        {:error, {:missing_project_route, project_slug(issue)}}
    end
  end

  defp project_prompt(%{prompt: path}, _default) when is_binary(path) and path != "" do
    case File.read(path) do
      {:ok, prompt} -> {:ok, prompt_template(prompt)}
      {:error, reason} -> {:error, {:missing_project_prompt, path, reason}}
    end
  end

  defp project_prompt(_route, default), do: {:ok, default}

  defp merge_route_backend(%Schema{} = settings, %{backend: backend}) when is_binary(backend),
    do: %{settings | agent: %{settings.agent | backend: backend}}

  defp merge_route_backend(settings, _route), do: settings

  defp merge_project_hooks(%Schema{} = settings, %{hooks: hooks}) when is_map(hooks) and map_size(hooks) > 0 do
    overrides =
      for {key, value} <- hooks, not is_nil(value), into: %{} do
        {String.to_existing_atom(to_string(key)), value}
      end

    %{settings | hooks: Map.merge(settings.hooks, overrides)}
  end

  defp merge_project_hooks(settings, _route), do: settings

  defp resolve_legacy(issue, %Schema{} = settings, supplied_route) do
    project_route = supplied_route || Config.linear_project_route(issue, settings)

    with {:ok, workflow} <- Workflow.current(),
         {:ok, environment} <- resolve_environment(issue, settings, project_route, nil) do
      {:ok,
       %__MODULE__{
         mode: :legacy,
         project_route: project_route,
         workflow_path: Workflow.workflow_file_path(),
         workflow: workflow,
         settings: put_environment(settings, environment),
         environment: environment,
         prompt_template: prompt_template(workflow.prompt_template)
       }}
    end
  end

  defp resolve_environment(issue, settings, project_route, repo_root) do
    opts =
      [route: project_route]
      |> then(&if(is_binary(repo_root), do: Keyword.put(&1, :repo_root, repo_root), else: &1))

    case Environment.resolve_optional(issue, settings, opts) do
      {:ok, environment} ->
        {:ok, environment}

      {:error, reason} ->
        {:error, {:environment_invalid, issue_identifier(issue), Environment.format_error(reason)}}
    end
  end

  defp put_environment(%Schema{} = settings, nil), do: settings

  defp put_environment(%Schema{} = settings, %Environment{} = environment) do
    %{settings | sandbox: %{settings.sandbox | environment: environment}}
  end

  defp issue_identifier(issue) when is_map(issue),
    do: Map.get(issue, :identifier) || Map.get(issue, "identifier")

  defp merge_settings(%Schema{} = settings, project_route, workflow) do
    updated_agent =
      settings.agent
      |> merge_struct_fields(workflow.agent, [
        :backend,
        :default_effort,
        :max_concurrent_agents,
        :max_turns,
        :max_retry_backoff_ms,
        :max_concurrent_agents_by_state
      ])
      |> Map.put(:backend, project_route.backend || workflow.agent.backend || settings.agent.backend)

    %{
      settings
      | agent: updated_agent,
        hooks: merge_struct_fields(settings.hooks, workflow.hooks, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms]),
        codex:
          merge_struct_fields(settings.codex, workflow.codex, [
            :command,
            :approval_policy,
            :thread_sandbox,
            :turn_sandbox_policy,
            :turn_timeout_ms,
            :read_timeout_ms,
            :stall_timeout_ms
          ]),
        opencode:
          merge_struct_fields(settings.opencode, workflow.opencode, [
            :command,
            :agent,
            :model,
            :turn_timeout_ms,
            :read_timeout_ms,
            :stall_timeout_ms
          ]),
        claude:
          merge_struct_fields(settings.claude, workflow.claude, [
            :command,
            :model,
            :permission_mode,
            :turn_timeout_ms,
            :read_timeout_ms,
            :stall_timeout_ms
          ])
    }
  end

  defp merge_struct_fields(base, overrides, fields) when is_list(fields) do
    Enum.reduce(fields, base, fn field, acc ->
      case Map.get(overrides, field) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
  end

  defp prompt_template(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.default_prompt_template()
    else
      prompt
    end
  end

  defp project_slug(%{project_slug: project_slug}) when is_binary(project_slug), do: project_slug
  defp project_slug(%{"project_slug" => project_slug}) when is_binary(project_slug), do: project_slug
  defp project_slug(_issue), do: nil
end
