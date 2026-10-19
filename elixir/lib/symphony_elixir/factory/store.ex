defmodule SymphonyElixir.Factory.Store do
  @moduledoc """
  Per-team factory definitions, keyed by Linear team key (e.g. `PAY`).

  Teams without a saved definition use `Definition.default_template/0`. Saves are
  optimistic: the caller passes the version it edited, and a save against a
  newer version is refused so two editors can't silently overwrite each other.

  Reads come from a public ETS table because the orchestrator resolves stages on
  every dispatch decision. Each team is persisted to
  `~/.symphony/factories/<TEAM>.json`.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Factory.Definition

  @table :symphony_factories
  @team_pattern ~r/^[A-Z0-9][A-Z0-9_-]{0,15}$/

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The definition for a team (or the default template). `nil` team = default.
  """
  @spec get(String.t() | nil) :: Definition.t()
  def get(team) do
    with key when is_binary(key) <- normalize_team(team),
         true <- :ets.whereis(@table) != :undefined,
         [{^key, definition}] <- :ets.lookup(@table, key) do
      definition
    else
      _ -> Map.put(Definition.default_template(), "team", normalize_team(team))
    end
  end

  @spec custom?(String.t() | nil) :: boolean()
  def custom?(team) do
    key = normalize_team(team)
    is_binary(key) and :ets.whereis(@table) != :undefined and :ets.member(@table, key)
  end

  @spec teams() :: [String.t()]
  def teams do
    if :ets.whereis(@table) != :undefined, do: @table |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> Enum.sort(), else: []
  end

  @doc """
  Saves a whole definition for a team. `base_version` must equal the stored
  version, or the save is refused with `{:error, {:conflict, current}}`.
  """
  @spec put(String.t(), map(), integer(), String.t()) ::
          {:ok, Definition.t()} | {:error, {:conflict, Definition.t()} | [String.t()] | atom()}
  def put(team, definition, base_version, updated_by) do
    GenServer.call(__MODULE__, {:put, team, definition, base_version, updated_by})
  end

  @doc """
  Updates one runtime control on a stage (paused, max_agents, harness, effort).
  Not version-checked: these are single-field toggles from the dashboard.
  """
  @spec put_stage_field(String.t(), String.t(), String.t(), term(), String.t()) :: {:ok, Definition.t()} | {:error, term()}
  def put_stage_field(team, stage_id, field, value, updated_by) when field in ["paused", "max_agents", "harness", "effort"] do
    GenServer.call(__MODULE__, {:put_stage_field, team, stage_id, field, value, updated_by})
  end

  def put_stage_field(_team, _stage_id, field, _value, _by), do: {:error, {:unknown_field, field}}

  @doc """
  Drops a team's custom definition so it falls back to the default template.
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
         current = get(key),
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
         current = get(key),
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

  def handle_call({:reset_team, team}, _from, state) do
    case team_key(team) do
      {:ok, key} ->
        :ets.delete(@table, key)
        if state.dir, do: File.rm(Path.join(state.dir, key <> ".json"))
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:reset_all, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

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

  defp team_key(team) do
    case normalize_team(team) do
      key when is_binary(key) -> if Regex.match?(@team_pattern, key), do: {:ok, key}, else: {:error, :invalid_team}
      _ -> {:error, :invalid_team}
    end
  end

  defp normalize_team(team) when is_binary(team), do: team |> String.trim() |> String.upcase()
  defp normalize_team(_team), do: nil

  defp default_dir do
    case Application.get_env(:symphony_elixir, :factories_dir, :default) do
      :default -> Path.expand("~/.symphony/factories")
      dir -> dir
    end
  end

  defp persist(nil, _key, _definition), do: :ok

  defp persist(dir, key, definition) do
    path = Path.join(dir, key <> ".json")

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
    key = path |> Path.basename(".json") |> String.upcase()

    with true <- Regex.match?(@team_pattern, key),
         {:ok, body} <- File.read(path),
         {:ok, raw} <- Jason.decode(body),
         {:ok, valid} <- Definition.validate(raw) do
      :ets.insert(@table, {key, valid |> Map.put("team", key) |> Map.put("version", raw["version"] || 1)})
    else
      other -> Logger.error("Factory definition skipped path=#{path} reason=#{inspect(other, limit: 5)}")
    end
  end
end
