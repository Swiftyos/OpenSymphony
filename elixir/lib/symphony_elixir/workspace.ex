defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel agent workers.
  """

  require Logger
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Config, IssueConfig, PathSafety, ProjectWorkflow, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @repo_cache_dir ".symphony-cache"
  @repo_branch_prefix "symphony/"
  @repo_cache_sync_ttl_ms 5_000

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil, opts \\ []) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, settings} <- resolve_settings(issue_or_identifier, opts),
           {:ok, workspace} <- workspace_path_for_issue(issue_context, safe_id, worker_host, settings),
           :ok <- validate_workspace_path(workspace, worker_host, settings),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host, settings),
           :ok <- maybe_bootstrap_workspace_repo(workspace, issue_context, created?, worker_host, settings),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host, settings) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil, _settings) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host, settings) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, hooks_timeout_ms(settings)) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t(), worker_host(), keyword()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, worker_host \\ nil, opts \\ [])

  def remove(workspace, nil, opts) do
    settings = settings_from_remove_opts(opts)

    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil, settings) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil, settings)
            remove_workspace_path(workspace, nil, settings)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        remove_workspace_path(workspace, nil, settings)
    end
  end

  def remove(workspace, worker_host, opts) when is_binary(worker_host) do
    settings = settings_from_remove_opts(opts)
    maybe_run_before_remove_hook(workspace, worker_host, settings)
    remove_workspace_path(workspace, worker_host, settings)
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(issue_or_identifier), do: remove_issue_workspaces(issue_or_identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(issue_or_identifier, worker_host) when is_binary(worker_host) do
    issue_context = issue_context(issue_or_identifier)
    safe_id = safe_identifier(issue_context.issue_identifier)
    settings = settings_for_cleanup(issue_or_identifier)

    issue_context
    |> workspace_roots_for_issue_context(settings)
    |> Enum.each(fn workspace_root ->
      workspace = Path.join(workspace_root, safe_id)
      remove(workspace, worker_host, settings: settings, issue_or_identifier: issue_or_identifier)
    end)

    :ok
  end

  def remove_issue_workspaces(issue_or_identifier, nil) do
    issue_context = issue_context(issue_or_identifier)
    settings = settings_for_cleanup(issue_or_identifier)

    case settings.worker.ssh_hosts do
      [] ->
        issue_context
        |> workspace_paths_for_issue_context(settings)
        |> Enum.each(&remove(&1, nil, settings: settings, issue_or_identifier: issue_or_identifier))

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(issue_or_identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec preflight_repo_setup(Schema.t()) :: :ok | {:error, term()}
  def preflight_repo_setup(%Schema{} = settings) do
    worker_hosts = [nil | List.wrap(settings.worker.ssh_hosts)] |> Enum.uniq()

    settings
    |> Config.linear_project_routes()
    |> Enum.reduce_while(:ok, fn route, :ok ->
      case Map.get(route, :repo) do
        repo when is_binary(repo) and repo != "" ->
          repo_source = Config.repo_source(repo)
          workspace_root = Config.workspace_root_for_route(route, settings)
          target_branch = Map.get(route, :default_branch)
          issue_context = route_issue_context(route)

          Enum.reduce_while(worker_hosts, :ok, fn worker_host, :ok ->
            case ensure_repo_cache(workspace_root, repo_source, target_branch, issue_context, worker_host, settings, force: true) do
              :ok ->
                case validate_project_route_workflow(route, workspace_root, repo_source, issue_context, worker_host, settings) do
                  :ok -> {:cont, :ok}
                  {:error, reason} -> {:halt, {:error, reason}}
                end

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end)
          |> case do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        _ ->
          {:cont, :ok}
      end
    end)
  end

  @spec preflight_repo_setup!(Schema.t()) :: :ok
  def preflight_repo_setup!(%Schema{} = settings) do
    case preflight_repo_setup(settings) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, message: format_repo_setup_error(reason)
    end
  end

  @spec ensure_local_repo_cache(map(), Schema.t()) :: {:ok, Path.t()} | {:error, term()}
  def ensure_local_repo_cache(%{repo: repo} = route, %Schema{} = settings)
      when is_binary(repo) and repo != "" do
    repo_source = Config.repo_source(repo)
    workspace_root = Config.workspace_root_for_route(route, settings)
    target_branch = Map.get(route, :default_branch)
    issue_context = route_issue_context(route)

    with :ok <- ensure_repo_cache(workspace_root, repo_source, target_branch, issue_context, nil, settings) do
      {:ok, repo_cache_path(workspace_root, repo_source)}
    end
  end

  def ensure_local_repo_cache(_route, _settings), do: {:error, :missing_project_repo}

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ [])
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    settings = settings_from_hook_opts(issue_or_identifier, opts)
    hooks = settings.hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host, settings)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ [])
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    settings = settings_from_hook_opts(issue_or_identifier, opts)
    hooks = settings.hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host, settings)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(issue_context, safe_id, nil, settings) when is_binary(safe_id) do
    issue_context
    |> Config.workspace_root_for_issue(settings)
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(issue_context, safe_id, worker_host, settings)
       when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.workspace_root_for_issue(issue_context, settings), safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_bootstrap_workspace_repo(_workspace, _issue_context, false, _worker_host, _settings), do: :ok

  defp maybe_bootstrap_workspace_repo(workspace, issue_context, true, worker_host, settings) do
    case Config.project_repo_source_for_issue(issue_context, settings) do
      %{display: _display} = repo_source ->
        bootstrap_workspace_repo(workspace, repo_source, issue_context, worker_host, settings)

      _ ->
        :ok
    end
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host, settings) do
    hooks = settings.hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host, settings)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil, settings) do
    hooks = settings.hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil,
              settings
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host, settings) when is_binary(worker_host) do
    hooks = settings.hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, hooks_timeout_ms(settings))
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil, settings) do
    timeout_ms = hooks_timeout_ms(settings)

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, settings)
       when is_binary(worker_host) do
    timeout_ms = hooks_timeout_ms(settings)

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil, settings) when is_binary(workspace) do
    case Config.validate_workspace_path(workspace, settings) do
      {:ok, _canonical_workspace} ->
        :ok

      {:error, {:workspace_root, canonical_workspace, canonical_root}} ->
        {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

      {:error, {:symlink_escape, expanded_workspace, canonical_root}} ->
        {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

      {:error, {:outside_workspace_root, canonical_workspace, canonical_root}} ->
        {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}

      {:error, {:path_unreadable, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host, _settings)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier} = issue) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      project_slug: Map.get(issue, :project_slug),
      project_name: Map.get(issue, :project_name)
    }
  end

  defp issue_context(%{identifier: identifier} = issue) do
    %{
      issue_id: Map.get(issue, :id),
      issue_identifier: identifier || "issue",
      project_slug: Map.get(issue, :project_slug),
      project_name: Map.get(issue, :project_name)
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      project_slug: nil,
      project_name: nil
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      project_slug: nil,
      project_name: nil
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier} = issue_context) do
    project_slug = Map.get(issue_context, :project_slug)
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"} project_slug=#{project_slug || "n/a"}"
  end

  defp workspace_roots_for_issue_context(%{project_slug: project_slug} = issue_context, settings)
       when is_binary(project_slug) do
    [Config.workspace_root_for_issue(issue_context, settings)]
  end

  defp workspace_roots_for_issue_context(_issue_context, settings) do
    Config.project_workspace_roots(settings)
  end

  defp workspace_paths_for_issue_context(issue_context, settings) do
    safe_id = safe_identifier(issue_context.issue_identifier)

    issue_context
    |> workspace_roots_for_issue_context(settings)
    |> Enum.map(&Path.join(&1, safe_id))
    |> Enum.uniq()
  end

  defp bootstrap_workspace_repo(workspace, repo_source, issue_context, worker_host, settings) do
    workspace_root = Config.workspace_root_for_issue(issue_context, settings)
    timeout_ms = hooks_timeout_ms(settings)
    branch_name = issue_branch_name(issue_context)
    target_branch = Config.project_default_branch_for_issue(issue_context, settings)
    cache_repo = repo_cache_path(workspace_root, repo_source)

    Logger.info(
      "Bootstrapping workspace repo #{issue_log_context(issue_context)} workspace=#{workspace} repo=#{repo_source.display} cache_repo=#{cache_repo} branch=#{branch_name} base_branch=#{target_branch || "origin-default"} worker_host=#{worker_host_for_log(worker_host)}"
    )

    with :ok <- ensure_repo_cache(workspace_root, repo_source, target_branch, issue_context, worker_host, settings),
         :ok <- add_workspace_worktree(workspace, cache_repo, branch_name, target_branch, repo_source, issue_context, worker_host, timeout_ms) do
      :ok
    end
  end

  defp ensure_repo_cache(workspace_root, repo_source, target_branch, issue_context, worker_host, settings, opts \\ [])

  defp ensure_repo_cache(workspace_root, repo_source, target_branch, issue_context, nil, settings, opts) do
    timeout_ms = hooks_timeout_ms(settings)
    cache_repo = repo_cache_path(workspace_root, repo_source)
    lock_key = repo_cache_lock_key(workspace_root, repo_source, target_branch, nil)
    force? = Keyword.get(opts, :force, false)

    with_repo_cache_lock(lock_key, fn ->
      if not force? and repo_cache_sync_fresh?(lock_key) do
        :ok
      else
        sync_local_repo_cache(workspace_root, repo_source, target_branch, issue_context, cache_repo, timeout_ms, lock_key)
      end
    end)
  end

  defp ensure_repo_cache(workspace_root, repo_source, target_branch, issue_context, worker_host, settings, opts)
       when is_binary(worker_host) do
    timeout_ms = hooks_timeout_ms(settings)
    cache_repo = repo_cache_path(workspace_root, repo_source)
    lock_key = repo_cache_lock_key(workspace_root, repo_source, target_branch, worker_host)
    force? = Keyword.get(opts, :force, false)

    with_repo_cache_lock(lock_key, fn ->
      if not force? and repo_cache_sync_fresh?(lock_key) do
        :ok
      else
        sync_remote_repo_cache(workspace_root, repo_source, target_branch, issue_context, worker_host, cache_repo, timeout_ms, lock_key)
      end
    end)
  end

  defp sync_local_repo_cache(workspace_root, repo_source, target_branch, issue_context, cache_repo, timeout_ms, lock_key) do
    Logger.info("Preparing workspace repo cache #{issue_log_context(issue_context)} workspace_root=#{workspace_root} repo=#{repo_source.display} cache_repo=#{cache_repo} worker_host=local")

    case run_local_script(build_repo_cache_sync_script(cache_repo, repo_source, target_branch), timeout_ms) do
      {:ok, {_output, 0}} ->
        mark_repo_cache_synced(lock_key)
        :ok

      {:ok, {output, status}} ->
        Logger.warning(
          "Workspace repo cache preparation failed #{issue_log_context(issue_context)} workspace_root=#{workspace_root} repo=#{repo_source.display} cache_repo=#{cache_repo} worker_host=local status=#{status} output=#{inspect(sanitize_hook_output_for_log(output))}"
        )

        {:error, {:workspace_repo_cache_failed, repo_source.display, status, output}}

      nil ->
        Logger.warning(
          "Workspace repo cache preparation timed out #{issue_log_context(issue_context)} workspace_root=#{workspace_root} repo=#{repo_source.display} cache_repo=#{cache_repo} worker_host=local timeout_ms=#{timeout_ms}"
        )

        {:error, {:workspace_repo_cache_timeout, repo_source.display, timeout_ms}}
    end
  end

  defp sync_remote_repo_cache(
         workspace_root,
         repo_source,
         target_branch,
         issue_context,
         worker_host,
         cache_repo,
         timeout_ms,
         lock_key
       ) do
    Logger.info("Preparing workspace repo cache #{issue_log_context(issue_context)} workspace_root=#{workspace_root} repo=#{repo_source.display} cache_repo=#{cache_repo} worker_host=#{worker_host}")

    case run_remote_command(worker_host, build_remote_repo_cache_sync_script(cache_repo, repo_source, target_branch), timeout_ms) do
      {:ok, {_output, 0}} ->
        mark_repo_cache_synced(lock_key)
        :ok

      {:ok, {output, status}} ->
        Logger.warning(
          "Workspace repo cache preparation failed #{issue_log_context(issue_context)} workspace_root=#{workspace_root} repo=#{repo_source.display} cache_repo=#{cache_repo} worker_host=#{worker_host} status=#{status} output=#{inspect(sanitize_hook_output_for_log(output))}"
        )

        {:error, {:workspace_repo_cache_failed, repo_source.display, status, output}}

      {:error, {:workspace_hook_timeout, "remote_command", _timeout_ms}} ->
        Logger.warning(
          "Workspace repo cache preparation timed out #{issue_log_context(issue_context)} workspace_root=#{workspace_root} repo=#{repo_source.display} cache_repo=#{cache_repo} worker_host=#{worker_host} timeout_ms=#{timeout_ms}"
        )

        {:error, {:workspace_repo_cache_timeout, repo_source.display, timeout_ms}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp with_repo_cache_lock(key, fun) when is_function(fun, 0) do
    :global.trans({__MODULE__, key}, fun, [node()], :infinity)
  end

  defp repo_cache_lock_key(workspace_root, repo_source, target_branch, worker_host) do
    {:symphony_repo_cache_sync, worker_host || :local, workspace_root, repo_source.cache_key, target_branch}
  end

  defp repo_cache_sync_fresh?(key) do
    case :persistent_term.get(key, nil) do
      timestamp when is_integer(timestamp) ->
        System.monotonic_time(:millisecond) - timestamp < @repo_cache_sync_ttl_ms

      _ ->
        false
    end
  end

  defp mark_repo_cache_synced(key) do
    :persistent_term.put(key, System.monotonic_time(:millisecond))
  end

  defp validate_project_route_workflow(%{workflow: workflow_ref}, workspace_root, repo_source, issue_context, nil, _settings)
       when is_binary(workflow_ref) and workflow_ref != "" do
    cache_repo = repo_cache_path(workspace_root, repo_source)

    case resolve_project_workflow(cache_repo, workflow_ref) do
      {:ok, workflow_path} ->
        case ProjectWorkflow.load(workflow_path) do
          {:ok, _workflow} ->
            :ok

          {:error, {:invalid_project_workflow_config, message}} ->
            {:error, {:invalid_workflow_config, "projects #{inspect(issue_context.project_slug)} workflow invalid: #{message}"}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_project_route_workflow(%{workflow: workflow_ref}, workspace_root, repo_source, _issue_context, worker_host, settings)
       when is_binary(workflow_ref) and workflow_ref != "" and is_binary(worker_host) do
    timeout_ms = hooks_timeout_ms(settings)
    cache_repo = repo_cache_path(workspace_root, repo_source)

    with {:ok, workflow_path} <- resolve_project_workflow(cache_repo, workflow_ref) do
      case run_remote_command(worker_host, build_remote_workflow_validation_script(workflow_path), timeout_ms) do
        {:ok, {_output, 0}} ->
          :ok

        {:ok, {_output, 42}} ->
          {:error, {:missing_workflow_file, workflow_path, :enoent}}

        {:ok, {output, status}} ->
          {:error, {:workspace_project_workflow_check_failed, workflow_path, status, output}}

        {:error, {:workspace_hook_timeout, "remote_command", _timeout_ms}} ->
          {:error, {:workspace_project_workflow_check_timeout, workflow_path, timeout_ms}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_project_route_workflow(_route, _workspace_root, _repo_source, _issue_context, _worker_host, _settings),
    do: :ok

  defp add_workspace_worktree(workspace, cache_repo, branch_name, target_branch, repo_source, issue_context, nil, timeout_ms) do
    case run_local_script(build_worktree_add_script(cache_repo, workspace, branch_name, target_branch), timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        Logger.warning(
          "Workspace repo worktree creation failed #{issue_log_context(issue_context)} workspace=#{workspace} repo=#{repo_source.display} cache_repo=#{cache_repo} branch=#{branch_name} worker_host=local status=#{status} output=#{inspect(sanitize_hook_output_for_log(output))}"
        )

        {:error, {:workspace_repo_worktree_failed, repo_source.display, status, output}}

      nil ->
        Logger.warning(
          "Workspace repo worktree creation timed out #{issue_log_context(issue_context)} workspace=#{workspace} repo=#{repo_source.display} cache_repo=#{cache_repo} branch=#{branch_name} worker_host=local timeout_ms=#{timeout_ms}"
        )

        {:error, {:workspace_repo_worktree_timeout, repo_source.display, timeout_ms}}
    end
  end

  defp add_workspace_worktree(workspace, cache_repo, branch_name, target_branch, repo_source, issue_context, worker_host, timeout_ms)
       when is_binary(worker_host) do
    case run_remote_command(worker_host, build_remote_worktree_add_script(cache_repo, workspace, branch_name, target_branch), timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        Logger.warning(
          "Workspace repo worktree creation failed #{issue_log_context(issue_context)} workspace=#{workspace} repo=#{repo_source.display} cache_repo=#{cache_repo} branch=#{branch_name} worker_host=#{worker_host} status=#{status} output=#{inspect(sanitize_hook_output_for_log(output))}"
        )

        {:error, {:workspace_repo_worktree_failed, repo_source.display, status, output}}

      {:error, {:workspace_hook_timeout, "remote_command", _timeout_ms}} ->
        Logger.warning(
          "Workspace repo worktree creation timed out #{issue_log_context(issue_context)} workspace=#{workspace} repo=#{repo_source.display} cache_repo=#{cache_repo} branch=#{branch_name} worker_host=#{worker_host} timeout_ms=#{timeout_ms}"
        )

        {:error, {:workspace_repo_worktree_timeout, repo_source.display, timeout_ms}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_workspace_path(workspace, nil, settings) do
    case maybe_remove_workspace_via_git_worktree(workspace, nil, hooks_timeout_ms(settings)) do
      :ok -> {:ok, []}
      :fallback -> File.rm_rf(workspace)
      {:error, reason} -> {:error, reason, ""}
    end
  end

  defp remove_workspace_path(workspace, worker_host, settings) when is_binary(worker_host) do
    case maybe_remove_workspace_via_git_worktree(workspace, worker_host, hooks_timeout_ms(settings)) do
      :ok -> {:ok, []}
      :fallback -> remove_remote_workspace_path(workspace, worker_host, settings)
      {:error, reason} -> {:error, reason, ""}
    end
  end

  defp maybe_remove_workspace_via_git_worktree(workspace, nil, timeout_ms) do
    case run_local_script(build_worktree_remove_script(workspace), timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {_output, 10}} -> :fallback
      {:ok, {output, status}} -> {:error, {:workspace_remove_failed, :local, status, output}}
      nil -> {:error, {:workspace_remove_timeout, :local, timeout_ms}}
    end
  end

  defp maybe_remove_workspace_via_git_worktree(workspace, worker_host, timeout_ms)
       when is_binary(worker_host) do
    case run_remote_command(worker_host, build_remote_worktree_remove_script(workspace), timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {_output, 10}} -> :fallback
      {:ok, {output, status}} -> {:error, {:workspace_remove_failed, worker_host, status, output}}
      {:error, {:workspace_hook_timeout, "remote_command", _timeout_ms}} -> {:error, {:workspace_remove_timeout, worker_host, timeout_ms}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_remote_workspace_path(workspace, worker_host, settings) do
    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, hooks_timeout_ms(settings)) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  defp build_repo_cache_sync_script(cache_repo, repo_source, target_branch) do
    script_lines =
      case repo_source.kind do
        :github_slug ->
          [
            "set -eu",
            "export GH_PROMPT_DISABLED=1",
            "export GIT_TERMINAL_PROMPT=0",
            "cache_repo=#{shell_escape(cache_repo)}",
            "repo_slug=#{shell_escape(repo_source.raw)}",
            "target_branch=#{shell_escape(target_branch || "")}",
            "mkdir -p \"$(dirname \"$cache_repo\")\"",
            "if ! command -v gh >/dev/null 2>&1; then",
            "  echo \"GitHub CLI (gh) is required to prepare #{repo_source.display}\" >&2",
            "  exit 44",
            "fi",
            "if ! gh auth status >/dev/null 2>&1; then",
            "  echo \"GitHub CLI is not authenticated for #{repo_source.display}\" >&2",
            "  exit 45",
            "fi",
            "protocol=\"$(gh config get git_protocol -h github.com 2>/dev/null || true)\"",
            "if [ -z \"$protocol\" ]; then",
            "  protocol=ssh",
            "fi",
            "if [ \"$protocol\" = \"https\" ]; then",
            "  remote_url=\"https://github.com/$repo_slug.git\"",
            "else",
            "  remote_url=\"git@github.com:$repo_slug.git\"",
            "fi",
            "if [ -e \"$cache_repo\" ] && ! git -C \"$cache_repo\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
            "  rm -rf \"$cache_repo\"",
            "fi",
            "if ! git -C \"$cache_repo\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
            "  rm -rf \"$cache_repo\"",
            "  gh repo clone \"$repo_slug\" \"$cache_repo\"",
            "fi",
            "git -C \"$cache_repo\" remote set-url origin \"$remote_url\"",
            "git -C \"$cache_repo\" fetch --prune origin",
            "git -C \"$cache_repo\" remote set-head origin --auto >/dev/null 2>&1 || true"
          ]

        _ ->
          [
            "set -eu",
            "export GIT_TERMINAL_PROMPT=0",
            "cache_repo=#{shell_escape(cache_repo)}",
            "clone_url=#{shell_escape(repo_source.clone_url)}",
            "target_branch=#{shell_escape(target_branch || "")}",
            "mkdir -p \"$(dirname \"$cache_repo\")\"",
            "if [ -e \"$cache_repo\" ] && ! git -C \"$cache_repo\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
            "  rm -rf \"$cache_repo\"",
            "fi",
            "if ! git -C \"$cache_repo\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
            "  rm -rf \"$cache_repo\"",
            "  git clone \"$clone_url\" \"$cache_repo\"",
            "fi",
            "git -C \"$cache_repo\" remote set-url origin \"$clone_url\"",
            "git -C \"$cache_repo\" fetch --prune origin",
            "git -C \"$cache_repo\" remote set-head origin --auto >/dev/null 2>&1 || true"
          ]
      end

    (script_lines ++
       resolve_target_branch_shell_lines("cache_repo", "target_branch") ++
       [
         "git -C \"$cache_repo\" checkout -f -B \"$target_branch\" \"origin/$target_branch\"",
         "git -C \"$cache_repo\" reset --hard \"origin/$target_branch\"",
         "git -C \"$cache_repo\" worktree prune"
       ])
    |> Enum.join("\n")
  end

  defp build_remote_repo_cache_sync_script(cache_repo, repo_source, target_branch) do
    script_lines =
      case repo_source.kind do
        :github_slug ->
          [
            "set -eu",
            "export GH_PROMPT_DISABLED=1",
            "export GIT_TERMINAL_PROMPT=0",
            remote_shell_assign("cache_repo", cache_repo),
            remote_shell_assign("repo_slug", repo_source.raw),
            remote_shell_assign("target_branch", target_branch || ""),
            "mkdir -p \"$(dirname \"$cache_repo\")\"",
            "if ! command -v gh >/dev/null 2>&1; then",
            "  echo \"GitHub CLI (gh) is required to prepare #{repo_source.display}\" >&2",
            "  exit 44",
            "fi",
            "if ! gh auth status >/dev/null 2>&1; then",
            "  echo \"GitHub CLI is not authenticated for #{repo_source.display}\" >&2",
            "  exit 45",
            "fi",
            "protocol=\"$(gh config get git_protocol -h github.com 2>/dev/null || true)\"",
            "if [ -z \"$protocol\" ]; then",
            "  protocol=ssh",
            "fi",
            "if [ \"$protocol\" = \"https\" ]; then",
            "  remote_url=\"https://github.com/$repo_slug.git\"",
            "else",
            "  remote_url=\"git@github.com:$repo_slug.git\"",
            "fi",
            "if [ -e \"$cache_repo\" ] && ! git -C \"$cache_repo\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
            "  rm -rf \"$cache_repo\"",
            "fi",
            "if ! git -C \"$cache_repo\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
            "  rm -rf \"$cache_repo\"",
            "  gh repo clone \"$repo_slug\" \"$cache_repo\"",
            "fi",
            "git -C \"$cache_repo\" remote set-url origin \"$remote_url\"",
            "git -C \"$cache_repo\" fetch --prune origin",
            "git -C \"$cache_repo\" remote set-head origin --auto >/dev/null 2>&1 || true"
          ]

        _ ->
          [
            "set -eu",
            "export GIT_TERMINAL_PROMPT=0",
            remote_shell_assign("cache_repo", cache_repo),
            remote_shell_assign("clone_url", repo_source.clone_url),
            remote_shell_assign("target_branch", target_branch || ""),
            "mkdir -p \"$(dirname \"$cache_repo\")\"",
            "if [ -e \"$cache_repo\" ] && ! git -C \"$cache_repo\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
            "  rm -rf \"$cache_repo\"",
            "fi",
            "if ! git -C \"$cache_repo\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
            "  rm -rf \"$cache_repo\"",
            "  git clone \"$clone_url\" \"$cache_repo\"",
            "fi",
            "git -C \"$cache_repo\" remote set-url origin \"$clone_url\"",
            "git -C \"$cache_repo\" fetch --prune origin",
            "git -C \"$cache_repo\" remote set-head origin --auto >/dev/null 2>&1 || true"
          ]
      end

    (script_lines ++
       resolve_target_branch_shell_lines("cache_repo", "target_branch") ++
       [
         "git -C \"$cache_repo\" checkout -f -B \"$target_branch\" \"origin/$target_branch\"",
         "git -C \"$cache_repo\" reset --hard \"origin/$target_branch\"",
         "git -C \"$cache_repo\" worktree prune"
       ])
    |> Enum.join("\n")
  end

  defp build_remote_workflow_validation_script(workflow_path) do
    [
      "set -eu",
      remote_shell_assign("workflow_path", workflow_path),
      "if [ -f \"$workflow_path\" ]; then",
      "  exit 0",
      "fi",
      "exit 42"
    ]
    |> Enum.join("\n")
  end

  defp build_worktree_add_script(cache_repo, workspace, branch_name, target_branch) do
    ([
       "set -eu",
       "cache_repo=#{shell_escape(cache_repo)}",
       "workspace=#{shell_escape(workspace)}",
       "branch_name=#{shell_escape(branch_name)}",
       "target_branch=#{shell_escape(target_branch || "")}"
     ] ++
       resolve_target_branch_shell_lines("cache_repo", "target_branch") ++
       [
         "git -C \"$cache_repo\" worktree prune",
         "git -C \"$cache_repo\" worktree add --force -B \"$branch_name\" \"$workspace\" \"origin/$target_branch\"",
         "git -C \"$workspace\" branch --set-upstream-to=\"origin/$target_branch\" \"$branch_name\" >/dev/null 2>&1 || true"
       ])
    |> Enum.join("\n")
  end

  defp build_remote_worktree_add_script(cache_repo, workspace, branch_name, target_branch) do
    ([
       "set -eu",
       remote_shell_assign("cache_repo", cache_repo),
       remote_shell_assign("workspace", workspace),
       remote_shell_assign("branch_name", branch_name),
       remote_shell_assign("target_branch", target_branch || "")
     ] ++
       resolve_target_branch_shell_lines("cache_repo", "target_branch") ++
       [
         "git -C \"$cache_repo\" worktree prune",
         "git -C \"$cache_repo\" worktree add --force -B \"$branch_name\" \"$workspace\" \"origin/$target_branch\"",
         "git -C \"$workspace\" branch --set-upstream-to=\"origin/$target_branch\" \"$branch_name\" >/dev/null 2>&1 || true"
       ])
    |> Enum.join("\n")
  end

  defp build_worktree_remove_script(workspace) do
    [
      "set -eu",
      "workspace=#{shell_escape(workspace)}",
      "if [ ! -d \"$workspace\" ]; then",
      "  exit 0",
      "fi",
      "if ! git -C \"$workspace\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
      "  exit 10",
      "fi",
      "common_dir=\"$(git -C \"$workspace\" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)\"",
      "workspace_git_dir=\"$(cd \"$workspace\" && pwd -P)/.git\"",
      "if [ -z \"$common_dir\" ] || [ \"$common_dir\" = \"$workspace_git_dir\" ]; then",
      "  exit 10",
      "fi",
      "cache_repo=\"$(cd \"$common_dir/..\" && pwd -P)\"",
      "git -C \"$cache_repo\" worktree remove --force \"$workspace\"",
      "git -C \"$cache_repo\" worktree prune"
    ]
    |> Enum.join("\n")
  end

  defp build_remote_worktree_remove_script(workspace) do
    [
      "set -eu",
      remote_shell_assign("workspace", workspace),
      "if [ ! -d \"$workspace\" ]; then",
      "  exit 0",
      "fi",
      "if ! git -C \"$workspace\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
      "  exit 10",
      "fi",
      "common_dir=\"$(git -C \"$workspace\" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)\"",
      "workspace_git_dir=\"$(cd \"$workspace\" && pwd -P)/.git\"",
      "if [ -z \"$common_dir\" ] || [ \"$common_dir\" = \"$workspace_git_dir\" ]; then",
      "  exit 10",
      "fi",
      "cache_repo=\"$(cd \"$common_dir/..\" && pwd -P)\"",
      "git -C \"$cache_repo\" worktree remove --force \"$workspace\"",
      "git -C \"$cache_repo\" worktree prune"
    ]
    |> Enum.join("\n")
  end

  defp resolve_target_branch_shell_lines(cache_repo_var_name, target_branch_var_name)
       when is_binary(cache_repo_var_name) and is_binary(target_branch_var_name) do
    [
      "if [ -n \"$#{target_branch_var_name}\" ]; then",
      "  if ! git -C \"$#{cache_repo_var_name}\" show-ref --verify --quiet \"refs/remotes/origin/$#{target_branch_var_name}\"; then",
      "    echo \"Configured branch not found on origin: $#{target_branch_var_name}\" >&2",
      "    exit 43",
      "  fi",
      "else",
      "  #{target_branch_var_name}=\"$(git -C \"$#{cache_repo_var_name}\" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)\"",
      "  if [ -z \"$#{target_branch_var_name}\" ]; then",
      "    if git -C \"$#{cache_repo_var_name}\" show-ref --verify --quiet refs/remotes/origin/main; then",
      "      #{target_branch_var_name}=origin/main",
      "    elif git -C \"$#{cache_repo_var_name}\" show-ref --verify --quiet refs/remotes/origin/master; then",
      "      #{target_branch_var_name}=origin/master",
      "    else",
      "      #{target_branch_var_name}=\"$(git -C \"$#{cache_repo_var_name}\" for-each-ref --count=1 --format='%(refname:short)' refs/remotes/origin | grep -v '^origin/HEAD$' | head -n 1)\"",
      "    fi",
      "  fi",
      "  #{target_branch_var_name}=\"${#{target_branch_var_name}#origin/}\"",
      "fi",
      "if [ -z \"$#{target_branch_var_name}\" ]; then",
      "  echo \"Unable to resolve origin default branch\" >&2",
      "  exit 41",
      "fi"
    ]
  end

  defp run_local_script(script, timeout_ms) when is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", script], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        {:ok, result}

      nil ->
        Task.shutdown(task, :brutal_kill)
        nil
    end
  end

  defp repo_cache_path(workspace_root, repo_source) when is_binary(workspace_root) do
    Path.join([workspace_root, @repo_cache_dir, repo_source.cache_key])
  end

  defp resolve_project_workflow(repo_root, workflow_ref) do
    case Config.resolve_project_workflow_path(repo_root, workflow_ref) do
      {:ok, workflow_path} ->
        if File.regular?(workflow_path) do
          {:ok, workflow_path}
        else
          {:error, {:missing_workflow_file, workflow_path, :enoent}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_branch_name(issue_context) do
    @repo_branch_prefix <> safe_identifier(issue_context.issue_identifier)
  end

  defp route_issue_context(%{slug: slug}) do
    %{
      issue_id: nil,
      issue_identifier: "__repo_preflight__",
      project_slug: slug,
      project_name: nil
    }
  end

  defp format_repo_setup_error(reason) do
    case reason do
      {:workspace_repo_cache_failed, repo, status, output} ->
        "Repository preflight failed for #{repo}: git exited with status #{status}: #{sanitize_hook_output_for_log(output, 512)}"

      {:workspace_repo_cache_timeout, repo, timeout_ms} ->
        "Repository preflight timed out for #{repo} after #{timeout_ms}ms"

      {:workspace_project_workflow_check_failed, workflow_path, status, output} ->
        "Repository preflight failed while checking project workflow #{workflow_path}: status #{status}: #{sanitize_hook_output_for_log(output, 512)}"

      {:workspace_project_workflow_check_timeout, workflow_path, timeout_ms} ->
        "Repository preflight timed out while checking project workflow #{workflow_path} after #{timeout_ms}ms"

      {:missing_workflow_file, path, raw_reason} ->
        Config.format_error({:missing_workflow_file, path, raw_reason})

      {:invalid_workflow_config, _message} = config_error ->
        Config.format_error(config_error)

      other ->
        "Repository preflight failed: #{inspect(other)}"
    end
  end

  defp resolve_settings(issue_or_identifier, opts) do
    case Keyword.get(opts, :settings) do
      %Schema{} = settings ->
        {:ok, settings}

      _ ->
        if Config.global_mode?() and is_map(issue_or_identifier) do
          case IssueConfig.resolve(issue_or_identifier) do
            {:ok, %IssueConfig{settings: settings}} -> {:ok, settings}
            {:error, reason} -> {:error, reason}
          end
        else
          {:ok, Config.settings!()}
        end
    end
  end

  defp settings_from_hook_opts(issue_or_identifier, opts) do
    case resolve_settings(issue_or_identifier, opts) do
      {:ok, settings} -> settings
      {:error, reason} -> raise ArgumentError, message: "Invalid issue settings: #{inspect(reason)}"
    end
  end

  defp settings_from_remove_opts(opts) do
    case Keyword.get(opts, :settings) do
      %Schema{} = settings -> settings
      _ -> Config.settings!()
    end
  end

  defp settings_for_cleanup(issue_or_identifier) do
    case resolve_settings(issue_or_identifier, []) do
      {:ok, settings} -> settings
      {:error, _reason} -> Config.settings!()
    end
  end

  defp hooks_timeout_ms(%Schema{hooks: hooks}) when is_map(hooks) do
    hooks.timeout_ms || 60_000
  end

  defp hooks_timeout_ms(_settings), do: 60_000
end
