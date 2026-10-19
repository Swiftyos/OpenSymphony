defmodule SymphonyElixir.Auth do
  @moduledoc """
  Who is using the dashboard and what they may do.

  Symphony keeps username/password accounts (`SymphonyElixir.Users`), but
  everything about *who someone is* comes from Linear: an account is tied to the
  Linear user with the same email, and that user's teams and admin flag decide
  permissions. Profiles are re-read from Linear every 10 minutes using Symphony's
  own tracker key, so changes in Linear (new team, removed admin, deactivated
  user) apply without touching Symphony.

  Modes:

    * `:local` - no sign-in; the local operator has full control. The default
      when the server binds to a loopback address.
    * `:accounts` - username/password sign-in. The default for any other address.

  `server.auth: local | accounts` overrides the default.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Users}
  alias SymphonyElixir.Linear.Client

  @table :symphony_auth_cache
  @profile_ttl_ms 600_000

  @member_query """
  query SymphonyMemberByEmail($email: String!) {
    users(filter: {email: {eqIgnoreCase: $email}}, first: 1) {
      nodes {
        id
        name
        displayName
        email
        avatarUrl
        admin
        guest
        active
        teams(first: 250) {
          nodes {
            id
            key
            name
          }
        }
      }
    }
  }
  """

  defmodule User do
    @moduledoc false
    @derive {Jason.Encoder, only: [:id, :username, :name, :email, :avatar_url, :admin, :guest, :local, :teams]}
    defstruct [
      :id,
      :username,
      :name,
      :email,
      :avatar_url,
      :linear_user_id,
      admin: false,
      guest: false,
      local: false,
      teams: []
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            username: String.t() | nil,
            name: String.t(),
            email: String.t() | nil,
            avatar_url: String.t() | nil,
            linear_user_id: String.t() | nil,
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

  @spec mode(map() | nil) :: :local | :accounts
  def mode(settings \\ nil) do
    settings = settings || Config.settings!()

    case settings.server.auth do
      "accounts" -> :accounts
      "local" -> :local
      _ -> if loopback?(settings.server.host), do: :local, else: :accounts
    end
  end

  @spec local_user() :: User.t()
  def local_user, do: %User{id: "local", name: "Local operator", admin: true, local: true}

  @doc """
  Sign-up gate: the email must belong to an active member of the Linear
  workspace. `:skip` when Symphony has no Linear tracker to ask (development).
  """
  @spec check_linear_member(String.t()) :: :ok | :skip | {:error, atom()}
  def check_linear_member(email) do
    case linear_profile(email) do
      {:ok, %{"active" => false}} -> {:error, :inactive_user}
      {:ok, _member} -> :ok
      other -> other
    end
  end

  @doc """
  Signs in with a username (or email) and password.
  """
  @spec sign_in(String.t(), String.t()) :: {:ok, User.t()} | {:error, atom()}
  def sign_in(login, password) do
    with {:ok, account} <- Users.authenticate(login, password) do
      user_for_account(account)
    end
  end

  @doc """
  Resolves the session's account id to a user with current Linear permissions.
  """
  @spec user_for_id(String.t() | nil, pos_integer() | nil) :: {:ok, User.t()} | {:error, atom()}
  def user_for_id(account_id, session_version \\ nil) do
    case Users.get(account_id) do
      # A password change or disable bumps the version and ends older sessions.
      %{session_version: version} when is_integer(session_version) and version != session_version -> {:error, :signed_out}
      %{status: "active"} = account -> user_for_account(account)
      %{status: "pending"} -> {:error, :pending}
      _ -> {:error, :signed_out}
    end
  end

  @spec user_for_account(map()) :: {:ok, User.t()} | {:error, atom()}
  def user_for_account(account) do
    base = %User{
      id: account.id,
      username: account.username,
      name: account.username,
      email: account.email,
      admin: account.bootstrap_admin
    }

    case linear_profile(account.email) do
      {:ok, %{"active" => false}} ->
        {:error, :inactive_user}

      {:ok, member} ->
        {:ok, with_linear_member(base, member, account.bootstrap_admin)}

      :skip ->
        {:ok, base}

      {:error, :not_in_workspace} ->
        {:error, :not_in_workspace}

      {:error, _reason} ->
        # Linear unreachable: keep the person signed in with no team rights
        # rather than locking everyone out.
        {:ok, base}
    end
  end

  defp with_linear_member(base, member, bootstrap_admin?) do
    teams =
      (get_in(member, ["teams", "nodes"]) || [])
      |> Enum.map(&%{id: &1["id"], key: &1["key"], name: &1["name"]})

    %{
      base
      | name: member["displayName"] || member["name"] || base.username,
        avatar_url: member["avatarUrl"],
        linear_user_id: member["id"],
        # The bootstrap account stays an admin so a fresh install can approve people.
        admin: bootstrap_admin? or member["admin"] == true,
        guest: member["guest"] == true and not bootstrap_admin?,
        teams: teams
    }
  end

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
  Whether the user may change factory-wide stage controls and approve accounts.
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
    SymphonyElixirWeb.RateLimit.create_table()
    {:ok, %{}}
  end

  # The Linear user with this email, looked up with Symphony's tracker key.
  defp linear_profile(email) when is_binary(email) do
    settings = Config.settings!()
    key = {:profile, String.downcase(email)}

    cond do
      settings.tracker.kind != "linear" or is_nil(settings.tracker.api_key) ->
        :skip

      cached = cache_get(key) ->
        {:ok, cached}

      true ->
        case client().graphql(@member_query, %{email: email}, []) do
          {:ok, %{"data" => %{"users" => %{"nodes" => [member | _]}}}} ->
            cache_put(key, member)
            {:ok, member}

          {:ok, %{"data" => %{"users" => %{"nodes" => []}}}} ->
            {:error, :not_in_workspace}

          other ->
            Logger.warning("Linear member lookup failed: #{inspect(other, limit: 5)}")
            {:error, :linear_unavailable}
        end
    end
  end

  defp linear_profile(_email), do: {:error, :not_in_workspace}

  defp cache_get(key) do
    now = System.monotonic_time(:millisecond)

    with true <- :ets.whereis(@table) != :undefined,
         [{^key, value, expires_at}] <- :ets.lookup(@table, key),
         true <- expires_at > now do
      value
    else
      _ -> nil
    end
  end

  defp cache_put(key, value) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {key, value, System.monotonic_time(:millisecond) + @profile_ttl_ms})
    end

    :ok
  end

  defp loopback?(host) when host in ["127.0.0.1", "::1", "localhost"], do: true
  defp loopback?("127." <> _rest), do: true
  defp loopback?(_host), do: false

  defp client, do: Application.get_env(:symphony_elixir, :linear_client_module, Client)
end
