defmodule SymphonyElixir.Auth do
  @moduledoc """
  Dashboard sign-in backed entirely by Linear.

  There is no user database. A person signs in with their own Linear personal API
  key; Symphony asks Linear who they are, which teams they belong to, and
  whether they are a workspace admin. Only members of the same Linear
  organization as Symphony's tracker key are accepted.

  Modes:

    * `:local` - no sign-in; the single local operator has full control. The
      default when the server binds to a loopback address.
    * `:linear` - Linear API key sign-in. The default for any other address.

  `server.auth: local | linear` overrides the default.

  Profiles are cached for #{div(600_000, 60_000)} minutes, keyed by a hash of the
  API key, so permissions follow Linear changes without a Linear call per request.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client

  @table :symphony_auth_cache
  @profile_ttl_ms 600_000

  @viewer_query """
  query SymphonyViewer {
    viewer {
      id
      name
      displayName
      email
      avatarUrl
      admin
      guest
      active
      organization {
        id
        urlKey
        name
      }
      teams(first: 250) {
        nodes {
          id
          key
          name
        }
      }
    }
  }
  """

  @organization_query """
  query SymphonyOrganization {
    organization {
      id
      urlKey
      name
    }
  }
  """

  defmodule User do
    @moduledoc false
    @derive {Jason.Encoder, only: [:id, :name, :email, :avatar_url, :admin, :guest, :local, :teams]}
    defstruct [:id, :name, :email, :avatar_url, :organization, admin: false, guest: false, local: false, teams: []]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            email: String.t() | nil,
            avatar_url: String.t() | nil,
            organization: map() | nil,
            admin: boolean(),
            guest: boolean(),
            local: boolean(),
            teams: [%{id: String.t(), key: String.t(), name: String.t()}]
          }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec mode(map() | nil) :: :local | :linear
  def mode(settings \\ nil) do
    settings = settings || Config.settings!()

    case settings.server.auth do
      "linear" -> :linear
      "local" -> :local
      _ -> if loopback?(settings.server.host), do: :local, else: :linear
    end
  end

  @spec local_user() :: User.t()
  def local_user, do: %User{id: "local", name: "Local operator", admin: true, local: true}

  @doc """
  Verifies a Linear API key and returns the signed-in user.
  """
  @spec sign_in(String.t()) :: {:ok, User.t()} | {:error, atom()}
  def sign_in(api_key) when is_binary(api_key) do
    api_key = String.trim(api_key)

    with :ok <- validate_key_shape(api_key),
         {:ok, viewer} <- fetch_viewer(api_key),
         :ok <- check_active(viewer),
         user = to_user(viewer),
         :ok <- check_organization(user) do
      cache_put({:user, key_hash(api_key)}, user)
      {:ok, user}
    end
  end

  def sign_in(_api_key), do: {:error, :invalid_key}

  @doc """
  Resolves the user for a stored session key, refreshing from Linear when the
  cached profile is stale.
  """
  @spec user_for_key(String.t() | nil) :: {:ok, User.t()} | {:error, atom()}
  def user_for_key(api_key) when is_binary(api_key) and api_key != "" do
    case cache_get({:user, key_hash(api_key)}) do
      %User{} = user -> {:ok, user}
      nil -> sign_in(api_key)
    end
  end

  def user_for_key(_api_key), do: {:error, :signed_out}

  @doc """
  Whether the user may move an issue (by identifier, e.g. `PAY-12`) between stages.
  """
  @spec can_move?(User.t() | nil, String.t() | nil) :: boolean()
  def can_move?(%User{local: true}, _identifier), do: true
  def can_move?(%User{admin: true}, _identifier), do: true
  def can_move?(%User{guest: true}, _identifier), do: false

  def can_move?(%User{teams: teams}, identifier) when is_binary(identifier) do
    case String.split(identifier, "-", parts: 2) do
      [team_key, _number] -> Enum.any?(teams, &(&1.key == team_key))
      _ -> false
    end
  end

  def can_move?(_user, _identifier), do: false

  @doc """
  Whether the user may change factory-wide stage controls.
  """
  @spec can_control?(User.t() | nil) :: boolean()
  def can_control?(%User{local: true}), do: true
  def can_control?(%User{admin: true}), do: true
  def can_control?(_user), do: false

  @doc """
  Team keys whose issues the user may move; `:all` for admins and local operators.
  """
  @spec movable_teams(User.t() | nil) :: :all | [String.t()]
  def movable_teams(%User{local: true}), do: :all
  def movable_teams(%User{admin: true}), do: :all
  def movable_teams(%User{guest: true}), do: []
  def movable_teams(%User{teams: teams}), do: Enum.map(teams, & &1.key)
  def movable_teams(_user), do: []

  @doc false
  @spec clear_cache() :: :ok
  def clear_cache do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  defp validate_key_shape(key) do
    if String.length(key) >= 20 and not String.contains?(key, [" ", "\n"]), do: :ok, else: {:error, :invalid_key}
  end

  defp fetch_viewer(api_key) do
    case client().graphql(@viewer_query, %{}, api_key: api_key) do
      {:ok, %{"data" => %{"viewer" => %{"id" => id} = viewer}}} when is_binary(id) ->
        {:ok, viewer}

      {:ok, %{"errors" => _errors}} ->
        {:error, :invalid_key}

      {:error, {:linear_api_status, status}} when status in [400, 401, 403] ->
        {:error, :invalid_key}

      {:error, reason} ->
        Logger.warning("Linear sign-in check failed: #{inspect(reason)}")
        {:error, :linear_unavailable}

      _ ->
        {:error, :invalid_key}
    end
  end

  defp to_user(viewer) do
    %User{
      id: viewer["id"],
      name: viewer["displayName"] || viewer["name"] || viewer["email"],
      email: viewer["email"],
      avatar_url: viewer["avatarUrl"],
      admin: viewer["admin"] == true,
      guest: viewer["guest"] == true,
      organization: viewer["organization"],
      teams:
        (get_in(viewer, ["teams", "nodes"]) || [])
        |> Enum.map(&%{id: &1["id"], key: &1["key"], name: &1["name"]})
    }
  end

  defp check_active(%{"active" => false}), do: {:error, :inactive_user}
  defp check_active(_viewer), do: :ok

  defp check_organization(%User{organization: %{"id" => org_id}}) do
    case expected_organization() do
      {:ok, %{"id" => ^org_id}} -> :ok
      {:ok, _other} -> {:error, :wrong_organization}
      :skip -> :ok
      {:error, _reason} -> {:error, :linear_unavailable}
    end
  end

  defp check_organization(_user), do: {:error, :wrong_organization}

  # The organization Symphony itself works in, from its tracker key. Without a
  # Linear tracker (e.g. the memory tracker in development) there is nothing to
  # compare against, so any valid Linear user is accepted.
  defp expected_organization do
    settings = Config.settings!()

    cond do
      settings.tracker.kind != "linear" or is_nil(settings.tracker.api_key) ->
        :skip

      org = cache_get(:organization) ->
        {:ok, org}

      true ->
        case client().graphql(@organization_query, %{}) do
          {:ok, %{"data" => %{"organization" => %{"id" => _} = org}}} ->
            cache_put(:organization, org, :infinity)
            {:ok, org}

          other ->
            {:error, other}
        end
    end
  end

  defp key_hash(key), do: :crypto.hash(:sha256, key)

  defp cache_get(key) do
    now = System.monotonic_time(:millisecond)

    with true <- :ets.whereis(@table) != :undefined,
         [{^key, value, expires_at}] <- :ets.lookup(@table, key),
         true <- expires_at == :infinity or expires_at > now do
      value
    else
      _ -> nil
    end
  end

  defp cache_put(key, value, ttl \\ @profile_ttl_ms) do
    if :ets.whereis(@table) != :undefined do
      expires_at = if ttl == :infinity, do: :infinity, else: System.monotonic_time(:millisecond) + ttl
      :ets.insert(@table, {key, value, expires_at})
    end

    :ok
  end

  defp loopback?(host) when host in ["127.0.0.1", "::1", "localhost"], do: true
  defp loopback?("127." <> _rest), do: true
  defp loopback?(_host), do: false

  defp client, do: Application.get_env(:symphony_elixir, :linear_client_module, Client)
end
