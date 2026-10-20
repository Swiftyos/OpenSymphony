defmodule SymphonyElixir.Factory.Store do
  @moduledoc """
  Factory definitions per scope: the organisation-wide `DEFAULT`, a Linear team
  (`PAY`), or a Linear project (`project:<slug>`).

  An issue uses the first flow that exists, most specific first: its project's,
  then its team's, then `DEFAULT`, then `Definition.default_template/0`. Saves are
  optimistic: the caller passes the version it edited, and a save against a
  newer version is refused so two editors can't silently overwrite each other.

  Reads come from a public ETS table because the orchestrator resolves stages on
  every dispatch decision. Each scope is persisted to
  `~/.symphony/factories/<TEAM>.json` or `project--<slug>.json`.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Factory.Definition

  @table :symphony_factories
  @team_pattern ~r/^[A-Z0-9][A-Z0-9_-]{0,15}$/
  @project_pattern ~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,95}$/
  @project_prefix "project:"
  @project_file_prefix "project--"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @default_team "DEFAULT"

  @doc """
  The flow for a scope (`nil` means `DEFAULT`). A scope without its own flow
  inherits: a project from `fallback_team` (the team its issues belong to), a
  team from `DEFAULT`, and `DEFAULT` from the built-in template.

  `"team"` is the scope asked for, `"source"` the scope the flow came from
  (`"template"` for the built-in one), and `"inherited"` whether they differ.
  """
  @spec get(String.t() | nil, String.t() | nil) :: Definition.t()
  def get(scope, fallback_team \\ nil) do
    key = normalize_scope(scope) || @default_team

    chain =
      if project_scope?(key), do: [key, normalize_scope(fallback_team), @default_team], else: [key, @default_team]

    {source, definition} =
      chain
      |> Enum.filter(&is_binary/1)
      |> Enum.find_value({"template", Definition.default_template()}, fn candidate ->
        if definition = lookup(candidate), do: {candidate, definition}
      end)

    definition
    |> Map.put("team", key)
    |> Map.put("source", source)
    |> Map.put("inherited", source != key)
  end

  @doc """
  The scope whose flow an issue follows: its project's when the project has its
  own flow, otherwise its team (which may itself inherit `DEFAULT`).
  """
  @spec scope_for(String.t() | nil, String.t() | nil) :: String.t() | nil
  def scope_for(team, project_slug) do
    project = project_scope(project_slug)
    if project && custom?(project), do: project, else: team
  end

  @doc """
  The scope key for a Linear project slug, or nil when the slug isn't usable.
  """
  @spec project_scope(String.t() | nil) :: String.t() | nil
  def project_scope(slug) when is_binary(slug) do
    slug = String.trim(slug)
    if Regex.match?(@project_pattern, slug), do: @project_prefix <> slug
  end

  def project_scope(_slug), do: nil

  @spec project_scope?(String.t() | nil) :: boolean()
  def project_scope?(@project_prefix <> _slug), do: true
  def project_scope?(_scope), do: false

  @spec default_team() :: String.t()
  def default_team, do: @default_team

  defp lookup(key) do
    with true <- :ets.whereis(@table) != :undefined,
         [{^key, definition}] <- :ets.lookup(@table, key) do
      definition
    else
      _ -> nil
    end
  end

  @spec custom?(String.t() | nil) :: boolean()
  def custom?(scope) do
    key = normalize_scope(scope)
    is_binary(key) and :ets.whereis(@table) != :undefined and :ets.member(@table, key)
  end

  @doc """
  Every scope with its own saved flow (teams, projects, and `DEFAULT`).
  """
  @spec scopes() :: [String.t()]
  def scopes do
    if :ets.whereis(@table) != :undefined, do: @table |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> Enum.sort(), else: []
  end

  @doc """
  Teams (and `DEFAULT`) with their own saved flow.
  """
  @spec teams() :: [String.t()]
  def teams, do: Enum.reject(scopes(), &project_scope?/1)

  @doc """
  Slugs of the projects with their own saved flow.
  """
  @spec projects() :: [String.t()]
  def projects, do: for(@project_prefix <> slug <- scopes(), do: slug)

  @doc """
  Saves a whole definition for a scope. `base_version` must equal the stored
  version, or the save is refused with `{:error, {:conflict, current}}`.
  """
  @spec put(String.t(), map(), integer(), String.t()) ::
          {:ok, Definition.t()} | {:error, {:conflict, Definition.t()} | [String.t()] | atom()}
  def put(team, definition, base_version, updated_by) do
    GenServer.call(__MODULE__, {:put, team, definition, base_version, updated_by})
  end

  @doc """
  Updates one runtime control on a stage (paused, approval, max_agents, harness,
  effort).
  Not version-checked: these are single-field toggles from the dashboard.
  """
  @spec put_stage_field(String.t(), String.t(), String.t(), term(), String.t()) ::
          {:ok, Definition.t()} | {:error, term()}
  def put_stage_field(team, stage_id, field, value, updated_by)
      when field in ["paused", "approval", "max_agents", "harness", "effort"] do
    GenServer.call(__MODULE__, {:put_stage_field, team, stage_id, field, value, updated_by})
  end

  def put_stage_field(_team, _stage_id, field, _value, _by), do: {:error, {:unknown_field, field}}

  @doc """
  Turns earned autonomy on or off for a scope and sets how many approvals in a
  row a stage needs before it stops asking. Changing it starts every stage's
  count again.
  """
  @spec put_autopilot(String.t(), boolean(), integer(), String.t()) :: {:ok, Definition.t()} | {:error, term()}
  def put_autopilot(scope, enabled, streak, updated_by) do
    GenServer.call(__MODULE__, {:put_autopilot, scope, enabled == true, streak, updated_by})
  end

  @doc """
  Records a person's verdict on a move an agent made out of `stage_id`:
  `:approved` adds one to the stage's streak, `:sent_back` resets it.
  """
  @spec record_review(String.t(), String.t(), :approved | :sent_back, String.t()) ::
          {:ok, Definition.t()} | {:error, term()}
  def record_review(scope, stage_id, verdict, updated_by) when verdict in [:approved, :sent_back] do
    GenServer.call(__MODULE__, {:record_review, scope, stage_id, verdict, updated_by})
  end

  @doc """
  Drops a scope's own definition so it inherits again (a project its team's
  flow, a team the `DEFAULT` flow, `DEFAULT` the built-in template).
  """
  @spec reset_team(String.t()) :: :ok
  def reset_team(team), do: GenServer.call(__MODULE__, {:reset_team, team})

  @doc false
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: GenServer.call(__MODULE__, :reset_all)
    :ok
  end

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir, default_dir())
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    load(dir)
    {:ok, %{dir: dir}}
  end

  @impl true
  def handle_call({:put, team, definition, base_version, updated_by}, _from, state) do
    with {:ok, key} <- team_key(team),
         current = own_or_new(key),
         :ok <- check_version(current, base_version),
         {:ok, valid} <- Definition.validate(definition) do
      saved = stamp(valid, key, current["version"] + 1, updated_by)
      :ets.insert(@table, {key, saved})
      persist(state.dir, key, saved)
      {:reply, {:ok, saved}, state}
    else
      {:conflict, current} -> {:reply, {:error, {:conflict, current}}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_stage_field, team, stage_id, field, value, updated_by}, _from, state) do
    with {:ok, key} <- team_key(team),
         current = own_or_new(key),
         %{} <- Definition.stage(current, stage_id) || {:error, {:unknown_stage, stage_id}},
         updated = update_stage(current, stage_id, field, value),
         {:ok, valid} <- Definition.validate(updated) do
      saved = stamp(valid, key, current["version"] + 1, updated_by)
      :ets.insert(@table, {key, saved})
      persist(state.dir, key, saved)
      {:reply, {:ok, saved}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_autopilot, scope, enabled, streak, updated_by}, _from, state) do
    update(state, scope, updated_by, fn current ->
      stages = Enum.map(current["stages"], &Map.put(&1, "approval_streak", 0))
      {:ok, %{current | "stages" => stages} |> Map.put("autopilot", %{"enabled" => enabled, "streak" => streak})}
    end)
  end

  def handle_call({:record_review, scope, stage_id, verdict, updated_by}, _from, state) do
    update(state, scope, updated_by, &review_streak(&1, stage_id, verdict))
  end

  def handle_call({:reset_team, team}, _from, state) do
    case team_key(team) do
      {:ok, key} ->
        :ets.delete(@table, key)
        if state.dir, do: File.rm(Path.join(state.dir, file_name(key)))
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:reset_all, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  defp review_streak(current, stage_id, verdict) do
    case Definition.stage(current, stage_id) do
      nil ->
        {:error, {:unknown_stage, stage_id}}

      stage ->
        streak = if verdict == :approved, do: (stage["approval_streak"] || 0) + 1, else: 0
        {:ok, update_stage(current, stage_id, "approval_streak", streak)}
    end
  end

  defp update(state, scope, updated_by, change) do
    with {:ok, key} <- team_key(scope),
         current = own_or_new(key),
         {:ok, changed} <- change.(current),
         {:ok, valid} <- Definition.validate(changed) do
      saved = stamp(valid, key, current["version"] + 1, updated_by)
      :ets.insert(@table, {key, saved})
      persist(state.dir, key, saved)
      {:reply, {:ok, saved}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # A scope that inherits starts its own copy from what it inherits, at version 0.
  defp own_or_new(key), do: lookup(key) || get(key) |> Map.put("version", 0)

  defp check_version(%{"version" => version}, version), do: :ok
  defp check_version(current, _base_version), do: {:conflict, current}

  defp update_stage(definition, stage_id, field, value) do
    stages = Enum.map(definition["stages"], fn stage -> if stage["id"] == stage_id, do: Map.put(stage, field, value), else: stage end)
    %{definition | "stages" => stages}
  end

  defp stamp(definition, key, version, updated_by) do
    definition
    |> Map.put("team", key)
    |> Map.put("version", version)
    |> Map.put("updated_by", updated_by)
    |> Map.put("updated_at", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
  end

  defp team_key(scope) do
    case normalize_scope(scope) do
      @project_prefix <> slug = key -> if Regex.match?(@project_pattern, slug), do: {:ok, key}, else: {:error, :invalid_team}
      key when is_binary(key) -> if Regex.match?(@team_pattern, key), do: {:ok, key}, else: {:error, :invalid_team}
      _ -> {:error, :invalid_team}
    end
  end

  # Team keys are upper-cased; project slugs keep their case.
  defp normalize_scope(scope) when is_binary(scope) do
    case String.trim(scope) do
      @project_prefix <> slug -> @project_prefix <> String.trim(slug)
      team -> String.upcase(team)
    end
  end

  defp normalize_scope(_scope), do: nil

  defp file_name(@project_prefix <> slug), do: @project_file_prefix <> slug <> ".json"
  defp file_name(team), do: team <> ".json"

  defp default_dir do
    case Application.get_env(:symphony_elixir, :factories_dir, :default) do
      :default -> Path.expand("~/.symphony/factories")
      dir -> dir
    end
  end

  defp persist(nil, _key, _definition), do: :ok

  defp persist(dir, key, definition) do
    path = Path.join(dir, file_name(key))

    case SymphonyElixir.PrivateFile.write(path, Jason.encode!(definition, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Factory save failed team=#{key} path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp load(nil), do: :ok

  defp load(dir) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.each(&load_file/1)
  end

  defp load_file(path) do
    key =
      case Path.basename(path, ".json") do
        @project_file_prefix <> slug -> @project_prefix <> slug
        team -> String.upcase(team)
      end

    with {:ok, ^key} <- team_key(key),
         {:ok, body} <- File.read(path),
         {:ok, raw} <- Jason.decode(body),
         {:ok, valid} <- Definition.validate(raw) do
      :ets.insert(@table, {key, valid |> Map.put("team", key) |> Map.put("version", raw["version"] || 1)})
    else
      other -> Logger.error("Factory definition skipped path=#{path} reason=#{inspect(other, limit: 5)}")
    end
  end
end
