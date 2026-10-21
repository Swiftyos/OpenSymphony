defmodule SymphonyElixir.GitMirror do
  @moduledoc """
  Read-only git access to the controller's repo caches, for runners that have
  no cache of their own.

  A runner clones and fetches from `/git/<run_id>/<repo-key>`, where the repo
  key is the cache key of a configured project repo (the same key
  `SymphonyElixir.Workspace` uses for the cache directory). A run may only read
  the repos of its own issue's project (`run_repos/2`): the issue's home repo,
  which the spec's mirror URL names (`mirror_for/2`), and the project's other
  repos, which the runner checks out read-only under `.symphony/repos/<name>`
  (`reference_commands/4`). A run whose metadata has no project slug at all may
  read only when exactly one project has a repo.

  The cache is served as it is and never changed for serving. Its local
  branches are not kept up to date, only `refs/remotes/origin/*` is, so a
  runner does not plain-clone the mirror: `clone_commands/3` builds a
  workspace the same way `SymphonyElixir.Workspace` clones one from the cache
  (`git init`, a fetch of `refs/remotes/origin/*` from the mirror, and a
  checkout of the issue branch when it exists or of the target branch).

  The endpoint never fetches from GitHub itself. When the cache is older than
  `workspace.repo_cache.max_age_ms`, it asks `RepoCacheRefresher` to sync in the
  background and advertises the refs it has now. Git reads are safe while
  another process fetches new objects and updates refs: the reader keeps the
  objects it has already opened, and ref updates are atomic. The cache lock is
  therefore not held for the request, which keeps a slow fetch from blocking
  every clone.
  """

  require Logger

  alias SymphonyElixir.{Config, RepoCacheRefresher, RunSpec, Workspace}
  alias SymphonyElixir.Config.Schema

  @fetched_at_file "symphony-fetched-at"
  @max_repo_key_bytes 128

  @typedoc "A configured project repo; servable once its cache exists on this controller."
  @type repo :: %{
          route: map(),
          name: String.t(),
          primary: boolean(),
          default_branch: String.t() | nil,
          repo_source: Config.repo_source(),
          repo_key: String.t(),
          cache_path: Path.t()
        }

  @doc "The URL-safe key that names a repo's cache directory."
  @spec repo_key(Config.repo_source()) :: String.t()
  def repo_key(%{cache_key: cache_key}), do: cache_key

  @doc """
  Maps a request's repo key to a configured repo whose cache exists.

  The key is matched against configured cache keys, never joined into a path,
  so traversal attempts are just unknown repos.
  """
  @spec resolve(String.t() | nil, Schema.t()) :: {:ok, repo()} | {:error, :unknown_repo}
  def resolve(repo_key, %Schema{} = settings)
      when is_binary(repo_key) and byte_size(repo_key) <= @max_repo_key_bytes do
    if String.match?(repo_key, ~r/\A[A-Za-z0-9._-]+\z/) do
      case Enum.find(candidates(settings), &(&1.repo_key == repo_key and File.dir?(&1.cache_path))) do
        nil -> {:error, :unknown_repo}
        repo -> {:ok, repo}
      end
    else
      {:error, :unknown_repo}
    end
  end

  def resolve(_repo_key, %Schema{}), do: {:error, :unknown_repo}

  @doc """
  The configured repos a run with this project slug may read, primary first.

  With a slug, the repos of the project route matching it (none when the slug
  matches no route or the route has no repo). Without a slug, the repos of the
  only project with a repo when there is exactly one, otherwise none. Both the
  endpoint's authorization and the spec's mirror URL use this lookup.
  """
  @spec run_repos(String.t() | nil, Schema.t()) :: [repo()]
  def run_repos(project_slug, %Schema{} = settings) do
    candidates = candidates(settings)

    if is_binary(project_slug) and String.trim(project_slug) != "" do
      case Config.linear_project_route(%{project_slug: project_slug}, settings) do
        %{slug: slug} -> Enum.filter(candidates, &(&1.route.slug == slug))
        nil -> []
      end
    else
      case candidates |> Enum.filter(& &1.primary) |> Enum.uniq_by(& &1.repo_key) do
        [%{route: %{slug: slug}}] -> Enum.filter(candidates, &(&1.route.slug == slug))
        _none_or_many -> []
      end
    end
  end

  @doc """
  The primary repo of `run_repos/2`.
  """
  @spec run_repo(String.t() | nil, Schema.t()) :: {:ok, repo()} | :none
  def run_repo(project_slug, %Schema{} = settings) do
    case run_repos(project_slug, settings) do
      [primary | _] -> {:ok, primary}
      [] -> :none
    end
  end

  @doc """
  Whether the run may read `repo`: only the repos `run_repos/2` lists for the
  project slug in the run's registry metadata.
  """
  @spec authorize(map() | nil, repo(), Schema.t()) :: :ok | {:error, :forbidden}
  def authorize(metadata, %{repo_key: repo_key}, %Schema{} = settings) do
    if Enum.any?(run_repos(metadata_value(metadata, :project_slug), settings), &(&1.repo_key == repo_key)) do
      :ok
    else
      Logger.warning(
        "Git mirror repo not allowed for run issue_identifier=#{metadata_value(metadata, :identifier) || "n/a"} project_slug=#{metadata_value(metadata, :project_slug) || "n/a"} repo=#{repo_key}"
      )

      {:error, :forbidden}
    end
  end

  @doc "The git URL a run clones from."
  @spec mirror_url(String.t(), String.t(), Config.repo_source()) :: String.t()
  def mirror_url(controller_url, run_id, repo_source)
      when is_binary(controller_url) and is_binary(run_id) do
    String.trim_trailing(controller_url, "/") <> "/git/" <> run_id <> "/" <> repo_key(repo_source)
  end

  @doc """
  The URL of another repo on the same mirror as `git_mirror_url` (a run's
  mirror URL names its home repo; its project's other repos sit beside it).
  """
  @spec repo_url(String.t(), Config.repo_source()) :: String.t()
  def repo_url(git_mirror_url, repo_source) when is_binary(git_mirror_url) do
    String.replace(git_mirror_url, ~r{/[^/]*$}, "/" <> repo_key(repo_source))
  end

  @doc """
  The mirror URL and target branch for a spec's issue, when this controller
  has the cache of the issue's home repo: the repo its `repo/<name>` label
  names among `run_repos/2`, else the project's primary.

  The target branch is that repo's configured `default_branch`, else the
  cache's `origin/HEAD`, else nil (the clone then falls back to `main` or
  `master`).
  """
  @spec mirror_for(RunSpec.t(), Schema.t()) :: %{url: String.t(), target_branch: String.t() | nil} | nil
  def mirror_for(%RunSpec{run_id: run_id, issue: issue, controller_url: controller_url}, %Schema{} = settings)
      when is_binary(run_id) and is_binary(controller_url) do
    with [primary | _] = repos <- run_repos(metadata_value(issue, :project_slug), settings),
         home = Config.issue_repo_for_route(issue, primary.route),
         %{} = repo <- Enum.find(repos, &(home && &1.name == home.name)) || primary,
         true <- File.dir?(repo.cache_path) do
      %{
        url: mirror_url(controller_url, run_id, repo.repo_source),
        target_branch: repo.default_branch || cache_default_branch(repo.cache_path)
      }
    else
      _ -> nil
    end
  end

  def mirror_for(_spec, %Schema{}), do: nil

  @doc """
  The commands a runner runs to create its workspace at `workspace` from the
  mirror: a shell script plus the environment to run it with.

  The script follows the controller's own workspace clone from the cache:
  `git init`, a fetch of `+refs/remotes/origin/*:refs/remotes/origin/*` from
  the mirror, then a checkout of `symphony/<issue>` from
  `origin/symphony/<issue>` when that branch exists (resuming a previous run's
  PR branch), else a new branch from `origin/<target_branch>`. The run token
  is in neither the script, the URL nor `.git/config`: the environment sets
  `http.extraHeader` through `GIT_CONFIG_COUNT`, which also keeps it out of
  the process list.

  `origin` is `:origin_url` (the repo's real remote, for pushes) when given,
  otherwise the mirror URL with the same `refs/remotes/origin/*` fetch
  refspec; a later fetch from the mirror needs the same environment.

      {:ok, %{script: script, env: env}} = GitMirror.clone_commands(spec, workspace)
      {_output, 0} = System.cmd("sh", ["-c", script], env: env, stderr_to_stdout: true)
  """
  @spec clone_commands(RunSpec.t(), Path.t(), keyword()) ::
          {:ok, %{script: String.t(), env: [{String.t(), String.t()}]}} | {:error, :no_git_mirror}
  def clone_commands(spec, workspace, opts \\ [])

  def clone_commands(%RunSpec{git_mirror_url: url, token: token} = spec, workspace, opts)
      when is_binary(url) and is_binary(token) and is_binary(workspace) do
    origin_url = Keyword.get(opts, :origin_url) || url

    # The mirror's own branches are stale; a mirror origin must keep fetching
    # the cache's remote-tracking refs, like the initial fetch does.
    origin_fetch =
      if origin_url == url,
        do: ["git -C \"$workspace\" config remote.origin.fetch '+refs/remotes/origin/*:refs/remotes/origin/*'"],
        else: []

    script =
      ([
         "set -eu",
         "export GIT_TERMINAL_PROMPT=0",
         "mirror_url=#{shell_escape(url)}",
         "origin_url=#{shell_escape(origin_url)}",
         "workspace=#{shell_escape(workspace)}",
         "branch_name=#{shell_escape(Workspace.issue_branch(metadata_value(spec.issue, :identifier)))}",
         "target_branch=#{shell_escape(spec.target_branch || "")}",
         "git init --quiet \"$workspace\"",
         "git -C \"$workspace\" remote add origin \"$origin_url\""
       ] ++
         origin_fetch ++
         [
           "git -C \"$workspace\" fetch --quiet --no-tags \"$mirror_url\" '+refs/remotes/origin/*:refs/remotes/origin/*'",
           "git -C \"$workspace\" config push.default current",
           "if [ -z \"$target_branch\" ]; then",
           "  for candidate in main master; do",
           "    if git -C \"$workspace\" show-ref --verify --quiet \"refs/remotes/origin/$candidate\"; then target_branch=\"$candidate\"; break; fi",
           "  done",
           "fi",
           # Recreating a workspace for an issue whose PR branch already exists
           # must resume that branch; resetting it to the base would orphan the PR.
           "if git -C \"$workspace\" show-ref --verify --quiet \"refs/remotes/origin/$branch_name\"; then",
           "  git -C \"$workspace\" checkout --quiet -B \"$branch_name\" \"origin/$branch_name\"",
           "  git -C \"$workspace\" branch --quiet --set-upstream-to=\"origin/$branch_name\" \"$branch_name\"",
           "elif [ -n \"$target_branch\" ] && git -C \"$workspace\" show-ref --verify --quiet \"refs/remotes/origin/$target_branch\"; then",
           "  git -C \"$workspace\" checkout --quiet --no-track -B \"$branch_name\" \"origin/$target_branch\"",
           "else",
           "  echo \"Target branch not found on the mirror: ${target_branch:-none}\" >&2",
           "  exit 43",
           "fi"
         ])
      |> Enum.join("\n")

    {:ok, %{script: script, env: auth_env(token)}}
  end

  def clone_commands(%RunSpec{}, _workspace, _opts), do: {:error, :no_git_mirror}

  @doc """
  The commands a runner runs to check out one of its project's other repos,
  read-only, at `target` (`.symphony/repos/<name>` in the workspace) from the
  mirror `url`: a fetch of `refs/remotes/origin/*` and a detached checkout of
  the target branch (`:target_branch`, else `main` or `master`). Run on every run, so the checkout follows the repo's latest
  default branch; local changes there are discarded.

  `origin` is `:origin_url` (the real remote), so the checkout names the repo
  it came from. With `:workspace`, the reference directory is added to the
  workspace's `.git/info/exclude`. Authentication is the run token in the
  environment, as for `clone_commands/3`.
  """
  @spec reference_commands(RunSpec.t(), String.t(), Path.t(), keyword()) ::
          {:ok, %{script: String.t(), env: [{String.t(), String.t()}]}} | {:error, :no_git_mirror}
  def reference_commands(%RunSpec{token: token}, url, target, opts)
      when is_binary(token) and is_binary(url) and is_binary(target) do
    workspace = Keyword.get(opts, :workspace)
    reference_dir = workspace && "/" <> Path.relative_to(Path.dirname(target), workspace) <> "/"

    exclude =
      if reference_dir do
        [
          "workspace=#{shell_escape(workspace)}",
          "if [ -d \"$workspace/.git\" ]; then",
          "  mkdir -p \"$workspace/.git/info\"",
          "  grep -qxF #{shell_escape(reference_dir)} \"$workspace/.git/info/exclude\" 2>/dev/null || " <>
            "printf '%s\\n' #{shell_escape(reference_dir)} >> \"$workspace/.git/info/exclude\"",
          "fi"
        ]
      else
        []
      end

    script =
      ([
         "set -eu",
         "export GIT_TERMINAL_PROMPT=0",
         "mirror_url=#{shell_escape(url)}",
         "origin_url=#{shell_escape(Keyword.get(opts, :origin_url) || url)}",
         "target=#{shell_escape(target)}",
         "target_branch=#{shell_escape(Keyword.get(opts, :target_branch) || "")}"
       ] ++
         exclude ++
         [
           "if [ ! -e \"$target/.git\" ]; then",
           "  rm -rf \"$target\"",
           "  mkdir -p \"$target\"",
           "  git init --quiet \"$target\"",
           "  git -C \"$target\" remote add origin \"$origin_url\"",
           "fi",
           "git -C \"$target\" fetch --quiet --no-tags --prune \"$mirror_url\" '+refs/remotes/origin/*:refs/remotes/origin/*'",
           "if [ -z \"$target_branch\" ] || ! git -C \"$target\" show-ref --verify --quiet \"refs/remotes/origin/$target_branch\"; then",
           "  for candidate in main master; do",
           "    if git -C \"$target\" show-ref --verify --quiet \"refs/remotes/origin/$candidate\"; then target_branch=\"$candidate\"; break; fi",
           "  done",
           "fi",
           "git -C \"$target\" checkout --quiet --force --detach \"origin/$target_branch\""
         ])
      |> Enum.join("\n")

    {:ok, %{script: script, env: auth_env(token)}}
  end

  def reference_commands(%RunSpec{}, _url, _target, _opts), do: {:error, :no_git_mirror}

  defp auth_env(token) do
    [
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "http.extraHeader"},
      {"GIT_CONFIG_VALUE_0", "Authorization: Bearer " <> token}
    ]
  end

  @doc "Whether the cache's last fetch is older than `max_age_ms`."
  @spec stale?(Path.t(), non_neg_integer()) :: boolean()
  def stale?(cache_path, max_age_ms)
      when is_binary(cache_path) and is_integer(max_age_ms) and max_age_ms >= 0 do
    max_age_ms == 0 or
      case File.read(Path.join([cache_path, ".git", @fetched_at_file])) do
        {:ok, contents} ->
          case Integer.parse(String.trim(contents)) do
            {fetched_at, ""} -> (System.system_time(:second) - fetched_at) * 1000 >= max_age_ms
            _ -> true
          end

        {:error, _reason} ->
          true
      end
  end

  @doc "Triggers a background cache sync when the cache is stale; never waits."
  @spec maybe_refresh(repo(), Schema.t(), keyword()) :: :ok
  def maybe_refresh(%{cache_path: cache_path} = repo, %Schema{} = settings, opts \\ []) do
    if stale?(cache_path, settings.workspace.repo_cache.max_age_ms) do
      refresher = Keyword.get(opts, :refresher, RepoCacheRefresher)

      Logger.info("Git mirror cache is stale; requesting background refresh repo=#{repo.repo_key}")

      RepoCacheRefresher.refresh_now(refresher)
    end

    :ok
  end

  # Every repo of every project route, primary first within a route. The
  # caches of a route's repos all live under its workspace root.
  defp candidates(%Schema{} = settings) do
    settings
    |> Config.linear_project_routes()
    |> Enum.flat_map(fn route ->
      root = Config.workspace_root_for_route(route, settings)

      for project_repo <- Config.project_repos(route) do
        repo_source = Config.repo_source(project_repo.repo)

        %{
          route: route,
          name: project_repo.name,
          primary: project_repo.primary,
          default_branch: project_repo.default_branch,
          repo_source: repo_source,
          repo_key: repo_key(repo_source),
          cache_path: Workspace.repo_cache_path(root, repo_source)
        }
      end
    end)
  end

  defp cache_default_branch(cache_path) do
    case System.cmd("git", ["-C", cache_path, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], stderr_to_stdout: true) do
      {"origin/" <> branch, 0} -> String.trim(branch)
      _other -> nil
    end
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil
end
