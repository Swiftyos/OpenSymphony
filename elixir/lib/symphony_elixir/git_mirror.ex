defmodule SymphonyElixir.GitMirror do
  @moduledoc """
  Read-only git access to the controller's repo caches, for runners that have
  no cache of their own.

  A runner clones and fetches from `/git/<run_id>/<repo-key>`, where the repo
  key is the cache key of a configured project repo (the same key
  `SymphonyElixir.Workspace` uses for the cache directory). A run may only read
  the repo of its own issue's project; a run whose registry metadata names no
  project repo is allowed any configured repo (with a warning), because older
  registries and the legacy single-project mode do not record one.

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

  @typedoc "A configured repo whose cache exists on this controller."
  @type repo :: %{
          route: map(),
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
  Whether the run may read `repo`.

  The run's registry metadata carries the issue's project slug. When it names
  a project with a configured repo, only that repo is allowed. Otherwise any
  configured repo is allowed; the gap is logged because those registries
  predate project repos or use the single-project fallback.
  """
  @spec authorize(map(), repo(), Schema.t()) :: :ok | {:error, :forbidden}
  def authorize(metadata, %{repo_source: repo_source}, %Schema{} = settings) do
    case project_repo_source(metadata, settings) do
      %{cache_key: key} when key == repo_source.cache_key ->
        :ok

      %{cache_key: _key} ->
        Logger.warning("Git mirror repo not owned by run issue_identifier=#{metadata_value(metadata, :identifier) || "n/a"} project_slug=#{metadata_value(metadata, :project_slug) || "n/a"}")

        {:error, :forbidden}

      nil ->
        Logger.warning(
          "Git mirror run has no project repo; allowing any configured repo issue_identifier=#{metadata_value(metadata, :identifier) || "n/a"} project_slug=#{metadata_value(metadata, :project_slug) || "n/a"}"
        )

        :ok
    end
  end

  @doc "The git URL a run clones from."
  @spec mirror_url(String.t(), String.t(), Config.repo_source()) :: String.t()
  def mirror_url(controller_url, run_id, repo_source)
      when is_binary(controller_url) and is_binary(run_id) do
    String.trim_trailing(controller_url, "/") <> "/git/" <> run_id <> "/" <> repo_key(repo_source)
  end

  @doc "The mirror URL for a spec's issue when this controller has its cache."
  @spec mirror_url_for(RunSpec.t(), Schema.t()) :: String.t() | nil
  def mirror_url_for(%RunSpec{run_id: run_id, issue: issue, controller_url: controller_url} = _spec, %Schema{} = settings)
      when is_binary(run_id) and is_binary(controller_url) do
    with %{} = repo_source <- Config.project_repo_source_for_issue(issue, settings),
         cache_path = Workspace.repo_cache_path(Config.workspace_root_for_issue(issue, settings), repo_source),
         true <- File.dir?(cache_path) do
      mirror_url(controller_url, run_id, repo_source)
    else
      _ -> nil
    end
  end

  def mirror_url_for(_spec, %Schema{}), do: nil

  @doc """
  A URL that clones the mirror with the run token as the password.

  Git sends HTTP basic auth for this form, so the controller accepts
  `x-access-token` (any user name) with the run token as the password.
  """
  @spec clone_url(RunSpec.t()) :: String.t() | nil
  def clone_url(%RunSpec{git_mirror_url: url, token: token}) when is_binary(url) and is_binary(token) do
    %{URI.parse(url) | userinfo: "x-access-token:" <> URI.encode_www_form(token)}
    |> URI.to_string()
  end

  def clone_url(_spec), do: nil

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

  defp candidates(%Schema{} = settings) do
    settings
    |> Config.linear_project_routes()
    |> Enum.flat_map(fn route ->
      case Map.get(route, :repo) do
        repo when is_binary(repo) and repo != "" ->
          repo_source = Config.repo_source(repo)

          [
            %{
              route: route,
              repo_source: repo_source,
              repo_key: repo_key(repo_source),
              cache_path:
                Workspace.repo_cache_path(
                  Config.workspace_root_for_route(route, settings),
                  repo_source
                )
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp project_repo_source(metadata, %Schema{} = settings) when is_map(metadata) do
    case metadata_value(metadata, :project_slug) do
      slug when is_binary(slug) and slug != "" ->
        case Config.linear_project_route(%{project_slug: slug}, settings) do
          %{repo: repo} when is_binary(repo) and repo != "" -> Config.repo_source(repo)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp project_repo_source(_metadata, %Schema{}), do: nil

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil
end
