defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel agent workers.
  """

  require Logger
  alias SymphonyElixir.Capacity.Metrics
  alias SymphonyElixir.{Config, IssueConfig, PathSafety, ProjectWorkflow, RepoCacheLock, Sandbox, SSH}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixirWeb.PrometheusMetrics

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @repo_cache_dir ".symphony-cache"
  @repo_cache_fetched_at_file "symphony-fetched-at"
  @repo_cache_sync_marker "__SYMPHONY_REPO_CACHE__"
  @repo_branch_prefix "symphony/"
  @reference_repos_dir ".symphony/repos"

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
           {:ok, created?} <-
             maybe_recreate_incomplete_workspace(
               workspace,
               issue_context,
               created?,
               worker_host,
               settings
             ),
           :ok <- initialize_new_workspace(workspace, issue_context, created?, worker_host, settings) do
        sync_reference_repos(workspace, issue_context, worker_host, settings)
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
          route
          |> preflight_route_repo_setup(worker_hosts, settings)
          |> reduce_while_result()

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp reduce_while_result(:ok), do: {:cont, :ok}
  defp reduce_while_result({:error, reason}), do: {:halt, {:error, reason}}

  # Every repo of the route gets a cache; the workflow is read from the primary.
  defp preflight_route_repo_setup(route, worker_hosts, settings) do
    workspace_root = Config.workspace_root_for_route(route, settings)
    issue_context = route_issue_context(route)

    for project_repo <- Config.project_repos(route), worker_host <- worker_hosts do
      {route, workspace_root, project_repo, issue_context, worker_host}
    end
    |> Enum.reduce_while(:ok, fn route_context, :ok ->
      route_context
      |> preflight_route_worker_host(settings)
      |> reduce_while_result()
    end)
  end

  defp preflight_route_worker_host({route, workspace_root, project_repo, issue_context, worker_host}, settings) do
    repo_source = Config.repo_source(project_repo.repo)

    with :ok <-
           ensure_repo_cache(
             workspace_root,
             repo_source,
             project_repo.default_branch,
             issue_context,
             worker_host,
             settings,
             force: true
           ) do
      if project_repo.primary,
        do: validate_project_route_workflow(route, workspace_root, repo_source, issue_context, worker_host, settings),
        else: :ok
    end
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

  @doc """
  Refreshes the cache clone for a project route on the local host.

  `SymphonyElixir.RepoCacheRefresher` calls this in the background so a workspace
  start usually finds the cache inside its freshness window and skips the remote
  fetch. Uses the same per-cache lock as the workspace flow, and honors
  `workspace.repo_cache.max_age_ms`.
  """
  @spec refresh_repo_cache(map(), Schema.t()) :: :ok | {:error, term()}
  def refresh_repo_cache(%{repo: repo} = route, %Schema{} = settings) when is_binary(repo) and repo != "" do
    workspace_root = Config.workspace_root_for_route(route, settings)
    issue_context = route_issue_context(route)

    route
    |> Config.project_repos()
    |> Enum.reduce(:ok, fn project_repo, result ->
      refreshed =
        ensure_repo_cache(
          workspace_root,
          Config.repo_source(project_repo.repo),
          project_repo.default_branch,
          issue_context,
          nil,
          settings,
          metric_reason: :refresher
        )

      # Keep refreshing the other repos; report the first failure.
      if result == :ok, do: refreshed, else: result
    end)
  end

  def refresh_repo_cache(_route, %Schema{}), do: :ok

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

  # A new workspace that fails to bootstrap must not survive: the next attempt
  # would see an existing directory, skip bootstrap and after_create, and run the
  # agent in an empty or half-installed checkout.
  defp initialize_new_workspace(workspace, issue_context, created?, worker_host, settings) do
    with :ok <- maybe_bootstrap_workspace_repo(workspace, issue_context, created?, worker_host, settings),
         :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host, settings) do
      :ok
    else
      {:error, reason} ->
        if created? do
          Logger.warning("Discarding incomplete workspace #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")
          discard_workspace(workspace, worker_host, settings)
        end

        {:error, reason}
    end
  end

  defp maybe_recreate_incomplete_workspace(_workspace, _issue_context, true, _worker_host, _settings), do: {:ok, true}

  defp maybe_recreate_incomplete_workspace(workspace, issue_context, false, worker_host, settings) do
    repo_configured? = match?(%{display: _}, Config.project_repo_source_for_issue(issue_context, settings))

    if repo_configured? and not workspace_git_repo?(workspace, worker_host, settings) do
      Logger.warning("Recreating workspace without a git checkout #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")
      discard_workspace(workspace, worker_host, settings)

      with {:ok, _workspace, created?} <- ensure_workspace(workspace, worker_host, settings) do
        {:ok, created?}
      end
    else
      {:ok, false}
    end
  end

  # Check for the workspace's own `.git`; `git rev-parse` would also succeed when a
  # parent directory happens to be a repository.
  defp workspace_git_repo?(workspace, nil, _settings) do
    File.exists?(Path.join(workspace, ".git"))
  end

  defp workspace_git_repo?(workspace, worker_host, settings) when is_binary(worker_host) do
    script = remote_shell_assign("workspace", workspace) <> "\n[ -e \"$workspace/.git\" ]"
    match?({:ok, {_output, 0}}, run_remote_command(worker_host, script, hooks_timeout_ms(settings)))
  end

  defp discard_workspace(workspace, nil, settings) do
    Sandbox.remove_container(workspace, settings)
    File.rm_rf(workspace)
    :ok
  end

  defp discard_workspace(workspace, worker_host, settings) when is_binary(worker_host) do
    remove_remote_workspace_path(workspace, worker_host, settings)
    :ok
  end

  @doc """
  Where the project's other repos are checked out in a workspace, relative to
  its root (`<dir>/<repo name>`).
  """
  @spec reference_repos_dir() :: String.t()
  def reference_repos_dir, do: @reference_repos_dir

  # The project's other repos (not the issue's home repo), checked out under
  # `.symphony/repos/<name>` at their default branch so the agent can read them
  # and describe a change one of them needs. Refreshed on every run (local edits
  # there are discarded); a failure is logged and the run goes on without it.
  defp sync_reference_repos(workspace, issue_context, worker_host, settings) do
    home = Config.issue_repo(issue_context, settings)
    workspace_root = Config.workspace_root_for_issue(issue_context, settings)

    for project_repo <- Config.project_repos(Config.linear_project_route(issue_context, settings)),
        home != nil and project_repo.name != home.name do
      sync_reference_repo(workspace, workspace_root, project_repo, issue_context, worker_host, settings)
    end

    :ok
  end

  defp sync_reference_repo(workspace, workspace_root, project_repo, issue_context, worker_host, settings) do
    repo_source = Config.repo_source(project_repo.repo)
    cache_repo = repo_cache_path(workspace_root, repo_source)
    target = Path.join([workspace, @reference_repos_dir, project_repo.name])
    timeout_ms = hooks_timeout_ms(settings)
    script = build_reference_repo_script(cache_repo, target, project_repo.default_branch, worker_host)

    branch = project_repo.default_branch

    with :ok <- ensure_repo_cache(workspace_root, repo_source, branch, issue_context, worker_host, settings),
         {:ok, {_output, 0}} <-
           with_repo_cache_lock(repo_cache_lock_key(workspace_root, repo_source, worker_host), fn ->
             run_workspace_script(script, worker_host, timeout_ms)
           end) do
      :ok
    else
      failure ->
        Logger.warning(
          "Reference repo checkout failed #{issue_log_context(issue_context)} workspace=#{workspace} repo=#{repo_source.display} worker_host=#{worker_host_for_log(worker_host)} result=#{inspect(reference_repo_failure(failure))}"
        )

        :error
    end
  end

  defp reference_repo_failure({:ok, {output, status}}), do: {:exit, status, sanitize_hook_output_for_log(output)}
  defp reference_repo_failure(other), do: other

  defp run_workspace_script(script, nil, timeout_ms), do: run_local_script(script, timeout_ms)
  defp run_workspace_script(script, worker_host, timeout_ms), do: run_remote_command(worker_host, script, timeout_ms)

  defp build_reference_repo_script(cache_repo, target, target_branch, worker_host) do
    assign = if worker_host, do: &remote_shell_assign/2, else: &"#{&1}=#{shell_escape(&2)}"

    ([
       "set -eu",
       assign.("cache_repo", cache_repo),
       assign.("target", target),
       assign.("target_branch", target_branch || "")
     ] ++
       resolve_target_branch_shell_lines("cache_repo", "target_branch") ++
       [
         "export GIT_TERMINAL_PROMPT=0",
         "if [ ! -e \"$target/.git\" ]; then",
         "  rm -rf \"$target\"",
         "  mkdir -p \"$(dirname \"$target\")\"",
         "  git clone --quiet --no-checkout \"$cache_repo\" \"$target\"",
         "  git -C \"$target\" remote set-url origin \"$(git -C \"$cache_repo\" remote get-url origin)\"",
         "fi",
         "git -C \"$target\" fetch --quiet --no-tags \"$cache_repo\" '+refs/remotes/origin/*:refs/remotes/origin/*'",
         "git -C \"$target\" checkout --quiet --force --detach \"origin/$target_branch\""
       ])
    |> Enum.join("\n")
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
      Task.async(fn -> run_local_hook_command(workspace, command, settings) end)

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

  defp run_local_hook_command(workspace, command, settings) do
    # Hooks run inside the workspace container when sandboxing is enabled so
    # dependency installs and builds stay isolated per issue.
    case Sandbox.command_spec(workspace, command, [], settings: settings, shell: "sh") do
      {:ok, %{executable: executable, args: args, cd: cd}} ->
        cmd_opts = if is_binary(cd), do: [cd: cd, stderr_to_stdout: true], else: [stderr_to_stdout: true]
        System.cmd(executable, args, cmd_opts)

      {:error, reason} ->
        {"sandbox unavailable: #{inspect(reason)}", 125}
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
      project_name: Map.get(issue, :project_name),
      labels: List.wrap(Map.get(issue, :labels))
    }
  end

  defp issue_context(%{identifier: identifier} = issue) do
    %{
      issue_id: Map.get(issue, :id),
      issue_identifier: identifier || "issue",
      project_slug: Map.get(issue, :project_slug),
      project_name: Map.get(issue, :project_name),
      labels: List.wrap(Map.get(issue, :labels))
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

    lock_key = repo_cache_lock_key(workspace_root, repo_source, worker_host)

    with :ok <-
           ensure_repo_cache(
             workspace_root,
             repo_source,
             target_branch,
             issue_context,
             worker_host,
             settings,
             issue_branch: branch_name
           ) do
      # Clone under the cache lock so a concurrent cache sync cannot move refs mid-clone.
      with_repo_cache_lock(lock_key, fn ->
        add_workspace_worktree(
          workspace,
          cache_repo,
          branch_name,
          target_branch,
          repo_source,
          issue_context,
          worker_host,
          timeout_ms
        )
      end)
    end
  end

  defp ensure_repo_cache(workspace_root, repo_source, target_branch, issue_context, worker_host, settings, opts \\ [])

  defp ensure_repo_cache(workspace_root, repo_source, target_branch, issue_context, nil, settings, opts) do
    timeout_ms = hooks_timeout_ms(settings)
    cache_repo = repo_cache_path(workspace_root, repo_source)
    lock_key = repo_cache_lock_key(workspace_root, repo_source, nil)
    sync_opts = repo_cache_sync_opts(settings, opts)

    with_repo_cache_lock(lock_key, fn ->
      sync_local_repo_cache(
        workspace_root,
        repo_source,
        target_branch,
        issue_context,
        cache_repo,
        timeout_ms,
        sync_opts
      )
    end)
  end

  defp ensure_repo_cache(workspace_root, repo_source, target_branch, issue_context, worker_host, settings, opts)
       when is_binary(worker_host) do
    timeout_ms = hooks_timeout_ms(settings)
    cache_repo = repo_cache_path(workspace_root, repo_source)
    lock_key = repo_cache_lock_key(workspace_root, repo_source, worker_host)
    sync_opts = repo_cache_sync_opts(settings, opts)

    with_repo_cache_lock(lock_key, fn ->
      sync_remote_repo_cache(
        workspace_root,
        repo_source,
        target_branch,
        issue_context,
        worker_host,
        cache_repo,
        timeout_ms,
        sync_opts
      )
    end)
  end

  # `force: true` (startup preflight) bypasses the freshness window: one fetch
  # per process start is cheap and keeps preflight's branch checks meaningful.
  defp repo_cache_sync_opts(settings, opts) do
    max_age_ms =
      if Keyword.get(opts, :force, false) do
        0
      else
        settings.workspace.repo_cache.max_age_ms
      end

    [
      max_age_ms: max_age_ms,
      issue_branch: Keyword.get(opts, :issue_branch),
      metric_reason: Keyword.get(opts, :metric_reason)
    ]
  end

  defp sync_local_repo_cache(workspace_root, repo_source, target_branch, issue_context, cache_repo, timeout_ms, sync_opts) do
    Logger.info("Preparing workspace repo cache #{issue_log_context(issue_context)} workspace_root=#{workspace_root} repo=#{repo_source.display} cache_repo=#{cache_repo} worker_host=local")

    sync_script = build_repo_cache_sync_script(cache_repo, repo_source, target_branch, sync_opts)

    case instrument_git_operation("cache_clone_or_fetch", fn -> run_local_script(sync_script, timeout_ms) end) do
      {:ok, {output, 0}} ->
        record_repo_cache_outcome(repo_source, output, issue_context, sync_opts)
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
         sync_opts
       ) do
    Logger.info("Preparing workspace repo cache #{issue_log_context(issue_context)} workspace_root=#{workspace_root} repo=#{repo_source.display} cache_repo=#{cache_repo} worker_host=#{worker_host}")

    sync_script = build_remote_repo_cache_sync_script(cache_repo, repo_source, target_branch, sync_opts)

    case instrument_git_operation("cache_clone_or_fetch", fn -> run_remote_command(worker_host, sync_script, timeout_ms) end) do
      {:ok, {output, 0}} ->
        record_repo_cache_outcome(repo_source, output, issue_context, sync_opts)
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

  defp record_repo_cache_outcome(repo_source, output, issue_context, sync_opts) do
    case parse_repo_cache_sync_outcome(output) do
      :skip ->
        Logger.debug("Repo cache is fresh; skipping remote fetch #{issue_log_context(issue_context)} repo=#{repo_source.display}")

        PrometheusMetrics.record_repo_cache_skip(repo_source.display)

      {:fetch, reason} ->
        PrometheusMetrics.record_repo_cache_fetch(
          repo_source.display,
          Keyword.get(sync_opts, :metric_reason) || reason
        )

      :unknown ->
        :ok
    end
  end

  defp parse_repo_cache_sync_outcome(output) do
    output
    |> IO.iodata_to_binary()
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "\t", parts: 3) do
        [@repo_cache_sync_marker, action, reason] -> {action, reason}
        _ -> nil
      end
    end)
    |> case do
      {"fetch", "first_clone"} -> {:fetch, :first_clone}
      {"fetch", _reason} -> {:fetch, :stale}
      {"skip", _reason} -> :skip
      _ -> :unknown
    end
  end

  defp with_repo_cache_lock(key, fun) when is_function(fun, 0) do
    RepoCacheLock.with_lock({__MODULE__, key}, fun)
  end

  defp repo_cache_lock_key(workspace_root, repo_source, worker_host) do
    {:symphony_repo_cache_sync, worker_host || :local, workspace_root, repo_source.cache_key}
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
    case instrument_git_operation("workspace_create", fn ->
           run_local_script(build_worktree_add_script(cache_repo, workspace, branch_name, target_branch), timeout_ms)
         end) do
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
    add_script = build_remote_worktree_add_script(cache_repo, workspace, branch_name, target_branch)

    case instrument_git_operation("workspace_create", fn ->
           run_remote_command(worker_host, add_script, timeout_ms)
         end) do
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
    Sandbox.remove_container(workspace, settings)

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
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {_output, 10}} ->
        :fallback

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}}

      {:error, {:workspace_hook_timeout, "remote_command", _timeout_ms}} ->
        {:error, {:workspace_remove_timeout, worker_host, timeout_ms}}

      {:error, reason} ->
        {:error, reason}
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

  defp build_repo_cache_sync_script(cache_repo, repo_source, target_branch, opts) do
    build_repo_cache_sync_script(cache_repo, repo_source, target_branch, opts, &local_shell_assign/2)
  end

  defp build_remote_repo_cache_sync_script(cache_repo, repo_source, target_branch, opts) do
    build_repo_cache_sync_script(cache_repo, repo_source, target_branch, opts, &remote_shell_assign/2)
  end

  defp local_shell_assign(variable_name, value) when is_binary(variable_name) and is_binary(value) do
    "#{variable_name}=#{shell_escape(value)}"
  end

  defp build_repo_cache_sync_script(cache_repo, repo_source, target_branch, opts, assign) do
    max_age_ms = Keyword.get(opts, :max_age_ms, 60_000)
    issue_branch = Keyword.get(opts, :issue_branch) || ""
    clone_setup_lines = repo_cache_clone_setup_lines(repo_source)
    clone_command = repo_cache_clone_command(repo_source)

    preamble_lines =
      repo_cache_preamble_lines(
        repo_source,
        cache_repo,
        target_branch,
        issue_branch,
        max_age_ms,
        assign
      )

    freshness_lines =
      [
        "if [ -e \"$cache_repo\" ] && ! git -C \"$cache_repo\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
        "  rm -rf \"$cache_repo\"",
        "fi",
        "first_clone=0",
        "if ! git -C \"$cache_repo\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
        "  rm -rf \"$cache_repo\""
      ] ++
        clone_setup_lines ++
        [
          "  #{clone_command}",
          "  first_clone=1",
          "fi",
          # A clone already fetched every ref, so it counts as the first fetch.
          "fetched_at_file=\"$cache_repo/.git/#{@repo_cache_fetched_at_file}\"",
          "action=skip",
          "reason=fresh",
          "if [ \"$first_clone\" = \"1\" ]; then",
          "  action=fetch",
          "  reason=first_clone",
          "  git -C \"$cache_repo\" remote set-url origin \"$repo_cache_remote_url\"",
          "  date +%s > \"$fetched_at_file\"",
          "elif [ \"$max_age_ms\" -eq 0 ]; then",
          "  action=fetch",
          "  reason=stale"
        ] ++
        clone_setup_lines ++
        [
          "  git -C \"$cache_repo\" remote set-url origin \"$repo_cache_remote_url\"",
          "  git -C \"$cache_repo\" fetch --prune origin",
          "  date +%s > \"$fetched_at_file\"",
          "  git -C \"$cache_repo\" remote set-head origin --auto >/dev/null 2>&1 || true",
          "else",
          "  fetched_at=0",
          "  if [ -f \"$fetched_at_file\" ]; then",
          "    fetched_at=\"$(cat \"$fetched_at_file\" 2>/dev/null || true)\"",
          "    case \"$fetched_at\" in ''|*[!0-9]*) fetched_at=0 ;; esac",
          "  fi",
          "  if [ $(( ($(date +%s) - fetched_at) * 1000 )) -lt \"$max_age_ms\" ]; then",
          # Within the window the cache is good enough; still refresh just the
          # issue branch with a single remote round trip so a PR branch pushed by
          # a different workspace is visible.
          "    action=skip",
          "    reason=fresh",
          "    if [ -n \"$issue_branch\" ]; then",
          "      set +e",
          "      fetch_output=\"$(LC_ALL=C git -C \"$cache_repo\" fetch --no-tags origin \"+refs/heads/$issue_branch:refs/remotes/origin/$issue_branch\" 2>&1)\"",
          "      fetch_status=$?",
          "      set -e",
          "      if [ \"$fetch_status\" -ne 0 ]; then",
          "        case \"$fetch_output\" in",
          "          *\"couldn't find remote ref\"*)",
          "            git -C \"$cache_repo\" update-ref -d \"refs/remotes/origin/$issue_branch\" >/dev/null 2>&1 || true",
          "            ;;",
          "          *)",
          "            printf '%s\\n' \"$fetch_output\" >&2",
          "            exit \"$fetch_status\"",
          "            ;;",
          "        esac",
          "      fi",
          "    fi",
          "  else",
          "    action=fetch",
          "    reason=stale"
        ] ++
        clone_setup_lines ++
        [
          "    git -C \"$cache_repo\" remote set-url origin \"$repo_cache_remote_url\"",
          "    git -C \"$cache_repo\" fetch --prune origin",
          "    date +%s > \"$fetched_at_file\"",
          "    git -C \"$cache_repo\" remote set-head origin --auto >/dev/null 2>&1 || true",
          "  fi",
          "fi",
          "printf '%s\\t%s\\t%s\\n' '#{@repo_cache_sync_marker}' \"$action\" \"$reason\""
        ]

    (preamble_lines ++
       freshness_lines ++
       resolve_target_branch_shell_lines("cache_repo", "target_branch") ++
       [
         # Keep the cache detached: a checked-out branch here would block
         # `git checkout <default>` in any linked worktree created before clones.
         "git -C \"$cache_repo\" checkout -f --detach \"origin/$target_branch\"",
         "git -C \"$cache_repo\" worktree prune"
       ])
    |> Enum.join("\n")
  end

  defp repo_cache_clone_setup_lines(%{kind: :github_slug} = repo_source) do
    [
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
      "repo_cache_remote_url=\"$remote_url\""
    ]
  end

  defp repo_cache_clone_setup_lines(_repo_source), do: ["repo_cache_remote_url=\"$clone_url\""]

  defp repo_cache_preamble_lines(repo_source, cache_repo, target_branch, issue_branch, max_age_ms, assign) do
    common = [
      "set -eu",
      "export GIT_TERMINAL_PROMPT=0",
      assign.("cache_repo", cache_repo),
      assign.("target_branch", target_branch || ""),
      assign.("issue_branch", issue_branch),
      assign.("max_age_ms", Integer.to_string(max_age_ms)),
      "mkdir -p \"$(dirname \"$cache_repo\")\""
    ]

    case repo_source.kind do
      :github_slug ->
        List.insert_at(common, 1, "export GH_PROMPT_DISABLED=1") ++
          [assign.("repo_slug", repo_source.raw)]

      _ ->
        common ++ [assign.("clone_url", repo_source.clone_url)]
    end
  end

  defp repo_cache_clone_command(%{kind: :github_slug}), do: "gh repo clone \"$repo_slug\" \"$cache_repo\""
  defp repo_cache_clone_command(_repo_source), do: "git clone \"$clone_url\" \"$cache_repo\""

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
       workspace_clone_shell_lines())
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
       workspace_clone_shell_lines())
    |> Enum.join("\n")
  end

  # Each workspace is a standalone clone of the cache (objects are hardlinked, so
  # it is cheap). Unlike `git worktree`, clones share no refs, index locks, or
  # checked-out-branch bookkeeping, so concurrent agents cannot block each other
  # on fetch/checkout/merge, and the workspace is self-contained for containers.
  defp workspace_clone_shell_lines do
    [
      "export GIT_TERMINAL_PROMPT=0",
      "remote_url=\"$(git -C \"$cache_repo\" remote get-url origin)\"",
      "git clone --quiet --no-checkout \"$cache_repo\" \"$workspace\"",
      "git -C \"$workspace\" fetch --quiet --no-tags \"$cache_repo\" '+refs/remotes/origin/*:refs/remotes/origin/*'",
      "git -C \"$workspace\" remote set-url origin \"$remote_url\"",
      "git -C \"$workspace\" config push.default current",
      # Recreating a workspace for an issue whose PR branch already exists must
      # resume that branch; resetting it to the base branch would orphan the PR.
      "if git -C \"$workspace\" show-ref --verify --quiet \"refs/remotes/origin/$branch_name\"; then",
      "  git -C \"$workspace\" checkout --quiet -B \"$branch_name\" \"origin/$branch_name\"",
      "  git -C \"$workspace\" branch --quiet --set-upstream-to=\"origin/$branch_name\" \"$branch_name\"",
      "else",
      "  git -C \"$workspace\" checkout --quiet --no-track -B \"$branch_name\" \"origin/$target_branch\"",
      "fi"
    ]
  end

  defp build_worktree_remove_script(workspace) do
    [
      "set -eu",
      "workspace=#{shell_escape(workspace)}",
      "if [ ! -d \"$workspace\" ]; then",
      "  exit 0",
      "fi",
      # Only a linked worktree (its own `.git` *file*, with itself as top level) is
      # removed through git. A clone or a plain directory, even one inside some other
      # checkout, falls back to a plain delete (still confined to the workspace root).
      "if [ ! -f \"$workspace/.git\" ]; then",
      "  exit 10",
      "fi",
      "toplevel=\"$(git -C \"$workspace\" rev-parse --show-toplevel 2>/dev/null || true)\"",
      "if [ \"$toplevel\" != \"$(cd \"$workspace\" && pwd -P)\" ]; then",
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
      # Only a linked worktree (its own `.git` *file*, with itself as top level) is
      # removed through git. A clone or a plain directory, even one inside some other
      # checkout, falls back to a plain delete (still confined to the workspace root).
      "if [ ! -f \"$workspace/.git\" ]; then",
      "  exit 10",
      "fi",
      "toplevel=\"$(git -C \"$workspace\" rev-parse --show-toplevel 2>/dev/null || true)\"",
      "if [ \"$toplevel\" != \"$(cd \"$workspace\" && pwd -P)\" ]; then",
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

  defp instrument_git_operation(operation, fun) when is_function(fun, 0) do
    started_at = System.monotonic_time()
    result = fun.()
    duration_seconds = System.convert_time_unit(System.monotonic_time() - started_at, :native, :microsecond) / 1_000_000
    outcome = git_operation_outcome(result)

    Metrics.record_counter("symphony_git_operations_total", operation: operation, outcome: outcome)
    Metrics.record_histogram("symphony_git_operation_duration_seconds", [operation: operation], duration_seconds)

    result
  end

  defp git_operation_outcome({:ok, {_output, 0}}), do: "ok"
  defp git_operation_outcome(_result), do: "error"

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

  @doc "The cache clone path for `repo_source` under a workspace root."
  @spec repo_cache_path(Path.t(), Config.repo_source()) :: Path.t()
  def repo_cache_path(workspace_root, repo_source) when is_binary(workspace_root) do
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

  defp issue_branch_name(issue_context), do: issue_branch(issue_context.issue_identifier)

  @doc "The branch an issue's workspace works on (`symphony/<identifier>`)."
  @spec issue_branch(String.t() | nil) :: String.t()
  def issue_branch(identifier), do: @repo_branch_prefix <> safe_identifier(identifier)

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
          resolve_issue_settings(issue_or_identifier)
        else
          {:ok, Config.settings!()}
        end
    end
  end

  defp resolve_issue_settings(issue_or_identifier) do
    case IssueConfig.resolve(issue_or_identifier) do
      {:ok, %IssueConfig{settings: settings}} -> {:ok, settings}
      {:error, reason} -> {:error, reason}
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
