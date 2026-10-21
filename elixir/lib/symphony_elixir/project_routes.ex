defmodule SymphonyElixir.ProjectRoutes do
  @moduledoc """
  Linear projects Symphony listens to that were added at runtime (through MCP)
  rather than in `symphony.yml`'s `projects:` block.

  Each route sends one Linear project's issues to one GitHub repo, exactly like
  a `projects:` entry: `Config.linear_project_routes/1` returns the file's
  routes followed by these, and a project in the file always wins over a stored
  one with the same slug. Changes apply on the next poll, no restart.

  Stored routes are deliberately narrower than file routes: the repo must be a
  GitHub `owner/name` (never a local path or another URL), the optional
  workflow a repo-relative path, and the workspace is always
  `workspace.root/<slug>`, so agents can't point Symphony at host paths.
  Without a workflow the project runs on Symphony's own config and prompt.

  Persisted through `SymphonyElixir.StateStore` (`~/.symphony/project_routes.json`).
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema.{TrackerProject, TrackerProjectRepo}
  alias SymphonyElixir.StateStore

  @table :symphony_project_routes
  @slug_pattern ~r/^[a-z0-9][a-z0-9-]{0,95}$/
  @repo_pattern ~r/^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/
  @branch_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}$/
  @repo_name_pattern ~r/^[a-z0-9][a-z0-9._-]{0,63}$/
  @backends ["codex", "claude", "opencode"]
  @max_routes 100
  @max_extra_repos 10
  @max_description 500

  @type route :: %{
          slug: String.t(),
          repo: String.t(),
          workflow: String.t() | nil,
          default_branch: String.t(),
          backend: String.t() | nil,
          repos: [%{name: String.t(), repo: String.t(), default_branch: String.t(), description: String.t() | nil}],
          added_by: String.t(),
          added_at: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Stored routes, by slug.
  """
  @spec list() :: [route()]
  def list do
    if ready?(), do: @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.slug), else: []
  end

  @doc """
  Stored routes in the shape of `symphony.yml` routes, for `Config`.
  """
  @spec tracker_projects() :: [struct()]
  def tracker_projects do
    Enum.map(list(), fn route ->
      %TrackerProject{
        slug: route.slug,
        repo: route.repo,
        workflow: route.workflow,
        backend: route.backend,
        default_branch: route.default_branch,
        workspace_root: nil,
        repos: Enum.map(route.repos, &struct(TrackerProjectRepo, &1))
      }
    end)
  end

  @doc """
  Adds a route, or replaces the stored one with the same slug.
  """
  @spec put(map(), String.t()) :: {:ok, route()} | {:error, String.t()}
  def put(attrs, added_by) when is_map(attrs), do: GenServer.call(__MODULE__, {:put, attrs, added_by})

  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(slug), do: GenServer.call(__MODULE__, {:delete, slug})

  @doc false
  @spec reset() :: :ok
  def reset do
    if ready?(), do: GenServer.call(__MODULE__, :reset)
    :ok
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    load(path)
    {:ok, %{path: path}}
  end

  @impl true
  def handle_call({:put, attrs, added_by}, _from, state) do
    with {:ok, route} <- validate(attrs, added_by),
         :ok <- check_limit(route.slug) do
      :ets.insert(@table, {route.slug, route})
      persist(state.path)
      Logger.info("Project route saved slug=#{route.slug} repo=#{route.repo} by=#{added_by}")
      {:reply, {:ok, route}, state}
    else
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:delete, slug}, _from, state) do
    if is_binary(slug) and :ets.member(@table, slug) do
      :ets.delete(@table, slug)
      persist(state.path)
      Logger.info("Project route removed slug=#{slug}")
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  defp ready?, do: :ets.whereis(@table) != :undefined

  defp check_limit(slug) do
    if :ets.member(@table, slug) or :ets.info(@table, :size) < @max_routes,
      do: :ok,
      else: {:error, "Symphony already listens to #{@max_routes} stored projects; remove one first."}
  end

  defp validate(attrs, added_by) do
    slug = attrs |> string("slug") |> String.downcase()
    repo = string(attrs, "repo")
    workflow = string(attrs, "workflow", nil)
    branch = string(attrs, "default_branch", "main")
    backend = string(attrs, "backend", nil)

    cond do
      not Regex.match?(@slug_pattern, slug) ->
        {:error, "slug must be the Linear project's slug id (the hex part of its URL, e.g. 9e8d7c6b5a40)."}

      not Regex.match?(@repo_pattern, repo) ->
        {:error, "repo must be a GitHub repository as owner/name, e.g. acme/widgets."}

      not optional_workflow?(workflow) ->
        {:error, "workflow must be a path inside the repo, e.g. WORKFLOW.md."}

      not Regex.match?(@branch_pattern, branch) or String.contains?(branch, "..") ->
        {:error, "default_branch isn't a valid branch name."}

      backend not in [nil | @backends] ->
        {:error, "backend must be one of #{Enum.join(@backends, ", ")}, or left out for the default."}

      true ->
        with {:ok, repos} <- validate_repos(Map.get(attrs, "repos"), repo) do
          {:ok,
           %{
             slug: slug,
             repo: repo,
             workflow: workflow,
             default_branch: branch,
             backend: backend,
             repos: repos,
             added_by: added_by,
             added_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
           }}
        end
    end
  end

  # The project's other repos, held to the same rules as the primary one.
  defp validate_repos(nil, _primary), do: {:ok, []}

  defp validate_repos(repos, primary) when is_list(repos) and length(repos) <= @max_extra_repos do
    repos
    |> Enum.reduce_while({:ok, [], MapSet.new([Config.repo_name(primary)])}, &add_repo/2)
    |> case do
      {:ok, repos, _names} -> {:ok, repos}
      {:error, message} -> {:error, message}
    end
  end

  defp validate_repos(_repos, _primary), do: {:error, "repos must be a list of at most #{@max_extra_repos} repos."}

  defp add_repo(entry, {:ok, acc, names}) do
    case validate_repo(entry) do
      {:ok, %{name: name} = repo} -> add_unique_repo(repo, acc, names, MapSet.member?(names, name))
      {:error, message} -> {:halt, {:error, message}}
    end
  end

  defp add_unique_repo(repo, acc, names, false), do: {:cont, {:ok, acc ++ [repo], MapSet.put(names, repo.name)}}

  defp add_unique_repo(repo, _acc, _names, true),
    do: {:halt, {:error, "repos has two repos named #{repo.name} (the primary repo is named after its last path segment); give one another name."}}

  defp validate_repo(%{} = attrs) do
    repo = string(attrs, "repo")
    name = repo_name(string(attrs, "name", nil), repo)
    branch = string(attrs, "default_branch", "main")
    description = string(attrs, "description", nil)

    cond do
      not Regex.match?(@repo_pattern, repo) ->
        {:error, "each of repos needs repo as a GitHub repository owner/name, e.g. acme/widgets-worker."}

      not Regex.match?(@repo_name_pattern, name) ->
        {:error, "repo names must be lowercase letters, digits, '.', '_' or '-' (#{inspect(name)})."}

      not Regex.match?(@branch_pattern, branch) or String.contains?(branch, "..") ->
        {:error, "default_branch of #{name} isn't a valid branch name."}

      is_binary(description) and String.length(description) > @max_description ->
        {:error, "the description of #{name} is longer than #{@max_description} characters."}

      true ->
        {:ok, %{name: name, repo: repo, default_branch: branch, description: description}}
    end
  end

  defp validate_repo(_attrs), do: {:error, "each of repos must be an object with repo (and optionally name, default_branch, description)."}

  defp repo_name(name, _repo) when is_binary(name), do: String.downcase(name)
  defp repo_name(nil, ""), do: ""
  defp repo_name(nil, repo), do: Config.repo_name(repo)

  defp string(attrs, key, default \\ "") do
    case Map.get(attrs, key) do
      value when is_binary(value) -> if String.trim(value) == "", do: default, else: String.trim(value)
      _ -> default
    end
  end

  defp optional_workflow?(nil), do: true
  defp optional_workflow?(path), do: safe_workflow_path?(path)

  defp safe_workflow_path?(path) do
    Path.type(path) == :relative and not String.starts_with?(path, "~") and
      ".." not in Path.split(path) and String.ends_with?(path, ".md")
  end

  defp default_path, do: Application.get_env(:symphony_elixir, :project_routes_path, Path.expand("~/.symphony/project_routes.json"))

  defp persist(nil), do: :ok

  defp persist(path) do
    case StateStore.write(path, Jason.encode!(%{version: 1, routes: list()}, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Project route save failed path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp load(nil), do: :ok

  defp load(path) do
    with {:ok, body} <- StateStore.read(path),
         {:ok, %{"routes" => routes}} when is_list(routes) <- Jason.decode(body) do
      Enum.each(routes, &load_route/1)
    else
      {:error, :enoent} -> :ok
      other -> Logger.error("Project route load failed path=#{path} reason=#{inspect(other, limit: 5)}")
    end
  end

  # Records are re-validated, so a hand-edited file can't widen what a route may do.
  defp load_route(%{} = raw) do
    case validate(raw, raw["added_by"] || "file") do
      {:ok, route} ->
        :ets.insert(@table, {route.slug, %{route | added_at: raw["added_at"] || route.added_at}})

      {:error, message} ->
        Logger.error("Project route skipped slug=#{inspect(raw["slug"])} reason=#{message}")
    end
  end

  defp load_route(_raw), do: :ok
end
