defmodule SymphonyElixir.Teams do
  @moduledoc """
  The Linear teams Symphony knows, whether or not they have projects, flows or
  work yet. A team is added by an admin (the Users page) or by the accounts
  import (`SymphonyElixir.Users.Import`) for every team its CSV names.

  A known team shows in the dashboard's team picker and the overview, can be
  given to people, and follows the default flow (`Factory.Store`'s `DEFAULT`)
  until it gets its own team flow or its projects get theirs.

  Each team keeps its Linear id, key, name and workflow states (name, type,
  position), looked up in Linear by id or key when it is added; the overview
  uses the states to group issues by Linear state across teams.

  Persisted through `SymphonyElixir.StateStore` (`~/.symphony/teams.json`).
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, StateStore}

  @table :symphony_teams
  @key_pattern ~r/^[A-Z0-9][A-Z0-9_-]{0,15}$/
  @uuid_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  @state_types ["triage", "backlog", "unstarted", "started", "completed", "canceled"]
  @lookup_query """
  query SymphonyTeamsLookup($ids: [ID!]!, $keys: [String!]!) {
    teams(first: 250, filter: {or: [{id: {in: $ids}}, {key: {in: $keys}}]}) {
      nodes {
        id
        key
        name
        states(first: 100) {
          nodes {
            name
            type
            position
          }
        }
      }
    }
  }
  """

  @type state :: %{name: String.t(), type: String.t(), position: number()}
  @type team :: %{
          key: String.t(),
          id: String.t() | nil,
          name: String.t() | nil,
          states: [state()],
          added_by: String.t(),
          added_at: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Known teams, by key."
  @spec list() :: [team()]
  def list do
    if ready?(), do: @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.key), else: []
  end

  @spec keys() :: [String.t()]
  def keys, do: Enum.map(list(), & &1.key)

  @spec get(String.t() | nil) :: team() | nil
  def get(key) when is_binary(key) do
    with true <- ready?(),
         [{_key, team}] <- :ets.lookup(@table, String.upcase(key)) do
      team
    else
      _ -> nil
    end
  end

  def get(_key), do: nil

  @doc "The known team with this Linear id."
  @spec by_id(String.t()) :: team() | nil
  def by_id(id) when is_binary(id), do: Enum.find(list(), &(&1.id == id))

  @doc "Team names by key, for labels."
  @spec names() :: %{String.t() => String.t()}
  def names, do: for(%{key: key, name: name} <- list(), is_binary(name), into: %{}, do: {key, name})

  @doc """
  The Linear state type (`started`, `completed`, ...) of a state name in a
  team's workflow, when the team's states are known.
  """
  @spec state_type(String.t() | nil, String.t() | nil) :: String.t() | nil
  def state_type(team, state) when is_binary(team) and is_binary(state) do
    case get(team) do
      %{states: states} -> Enum.find_value(states, &(normalize(&1.name) == normalize(state) && &1.type))
      nil -> nil
    end
  end

  def state_type(_team, _state), do: nil

  @spec state_types() :: [String.t()]
  def state_types, do: @state_types

  @doc """
  Adds teams (or refreshes known ones: name, id, states). Each needs a `key`;
  `id`, `name` and `states` are optional. A known team keeps when and by whom
  it was first added.
  """
  @spec register([map()], String.t()) :: {:ok, [team()]} | {:error, String.t()}
  def register(teams, added_by) when is_list(teams), do: GenServer.call(__MODULE__, {:register, teams, added_by})

  @spec remove(String.t()) :: :ok | {:error, :not_found}
  def remove(key), do: GenServer.call(__MODULE__, {:remove, key})

  @doc """
  Looks teams up in Linear by id or key, with Symphony's Linear API key. Returns
  the teams found as `register/2` takes them, and the refs Linear didn't return
  (the key can't see those teams, or they don't exist).
  """
  @spec lookup([String.t()]) :: {:ok, [map()], [String.t()]} | {:error, term()}
  def lookup(refs) when is_list(refs) do
    {ids, keys} = refs |> clean() |> Enum.split_with(&Regex.match?(@uuid_pattern, &1))
    lookup(ids, Enum.map(keys, &String.upcase/1))
  end

  @doc "Like `lookup/1`, for refs already known to be ids and keys."
  @spec lookup([String.t()], [String.t()]) :: {:ok, [map()], [String.t()]} | {:error, term()}
  def lookup(ids, keys) when is_list(ids) and is_list(keys) do
    ids = clean(ids)
    keys = clean(keys)

    cond do
      ids == [] and keys == [] ->
        {:ok, [], []}

      not linear?() ->
        {:error, :linear_not_configured}

      true ->
        client().graphql(@lookup_query, %{ids: ids, keys: keys}, []) |> lookup_result(ids, keys)
    end
  end

  defp lookup_result({:ok, %{"data" => %{"teams" => %{"nodes" => nodes}}}}, ids, keys) when is_list(nodes) do
    found = Enum.map(nodes, &from_linear/1)
    missing_ids = Enum.reject(ids, fn id -> Enum.any?(found, &(&1.id == id)) end)
    missing_keys = Enum.reject(keys, fn key -> Enum.any?(found, &(&1.key == key)) end)
    {:ok, found, missing_ids ++ missing_keys}
  end

  defp lookup_result(other, _ids, _keys), do: {:error, {:linear_teams_unavailable, inspect(other, limit: 3)}}

  @doc """
  Looks teams up in Linear (`lookup/1`) and adds the ones found. Returns the
  added teams and the refs Linear didn't return.
  """
  @spec add_from_linear([String.t()], String.t()) :: {:ok, [team()], [String.t()]} | {:error, term()}
  def add_from_linear(refs, added_by) do
    with {:ok, found, missing} <- lookup(refs),
         {:ok, added} <- register(found, added_by) do
      {:ok, added, missing}
    end
  end

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
  def handle_call({:register, teams, added_by}, _from, state) do
    case validate_all(teams, added_by) do
      {:ok, valid} ->
        saved =
          Enum.map(valid, fn team ->
            merged = merge(get(team.key), team)
            :ets.insert(@table, {merged.key, merged})
            merged
          end)

        if saved != [] do
          persist(state.path)
          Logger.info("Teams registered keys=#{Enum.map_join(saved, ",", & &1.key)} by=#{added_by}")
        end

        {:reply, {:ok, saved}, state}

      {:error, message} ->
        {:reply, {:error, message}, state}
    end
  end

  def handle_call({:remove, key}, _from, state) do
    key = if is_binary(key), do: String.upcase(String.trim(key))

    if is_binary(key) and :ets.member(@table, key) do
      :ets.delete(@table, key)
      persist(state.path)
      Logger.info("Team removed key=#{key}")
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # A known team keeps its first `added_*`; Linear's newer facts win, but a
  # lookup without states (a CSV-only team) doesn't wipe known states.
  defp merge(nil, team), do: team

  defp merge(old, team) do
    %{
      team
      | id: team.id || old.id,
        name: team.name || old.name,
        states: if(team.states == [], do: old.states, else: team.states),
        added_by: old.added_by,
        added_at: old.added_at
    }
  end

  defp validate_all(teams, added_by) do
    Enum.reduce_while(teams, {:ok, []}, fn attrs, {:ok, acc} ->
      case validate(attrs, added_by) do
        {:ok, team} -> {:cont, {:ok, acc ++ [team]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp validate(%{} = attrs, added_by) do
    key = attrs |> field(:key) |> then(&(is_binary(&1) && String.upcase(String.trim(&1))))

    if is_binary(key) and Regex.match?(@key_pattern, key) do
      {:ok,
       %{
         key: key,
         id: string(field(attrs, :id)),
         name: string(field(attrs, :name)),
         states: attrs |> field(:states) |> List.wrap() |> Enum.flat_map(&state/1),
         added_by: string(field(attrs, :added_by)) || added_by,
         added_at: string(field(attrs, :added_at)) || now()
       }}
    else
      {:error, "#{inspect(key)} isn't a Linear team key (like PAY)."}
    end
  end

  defp validate(_attrs, _added_by), do: {:error, "A team must be an object with a key."}

  defp state(%{} = attrs) do
    name = string(field(attrs, :name))
    type = string(field(attrs, :type))
    position = field(attrs, :position)

    if is_binary(name) and type in @state_types,
      do: [%{name: name, type: type, position: if(is_number(position), do: position, else: 0)}],
      else: []
  end

  defp state(_attrs), do: []

  defp from_linear(node) do
    %{
      key: node["key"],
      id: node["id"],
      name: node["name"],
      states: get_in(node, ["states", "nodes"]) || []
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp clean(refs), do: refs |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

  defp field(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp string(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp string(_value), do: nil

  defp normalize(value), do: value |> String.trim() |> String.downcase()

  defp linear? do
    settings = Config.settings!()
    settings.tracker.kind == "linear" and is_binary(settings.tracker.api_key)
  end

  defp client, do: Application.get_env(:symphony_elixir, :linear_client_module, SymphonyElixir.Linear.Client)

  defp ready?, do: :ets.whereis(@table) != :undefined

  defp default_path, do: Application.get_env(:symphony_elixir, :teams_path, Path.expand("~/.symphony/teams.json"))

  defp persist(nil), do: :ok

  defp persist(path) do
    case StateStore.write(path, Jason.encode!(%{version: 1, teams: list()}, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Teams save failed path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp load_team(raw) do
    case validate(raw, "file") do
      {:ok, team} -> :ets.insert(@table, {team.key, team})
      {:error, message} -> Logger.error("Team skipped key=#{inspect(raw["key"])} reason=#{message}")
    end
  end

  defp load(nil), do: :ok

  defp load(path) do
    with {:ok, body} <- StateStore.read(path),
         {:ok, %{"teams" => teams}} when is_list(teams) <- Jason.decode(body) do
      Enum.each(teams, &load_team/1)
    else
      {:error, :enoent} -> :ok
      other -> Logger.error("Teams load failed path=#{path} reason=#{inspect(other, limit: 5)}")
    end
  end
end
