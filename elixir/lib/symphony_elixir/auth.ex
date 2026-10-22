defmodule SymphonyElixir.Auth do
  @moduledoc """
  Who is using the dashboard. What that allows is `SymphonyElixir.Policy`'s.

  Google Identity-Aware Proxy in front of the dashboard signs people in; the
  signed IAP header (`SymphonyElixir.Iap`) gives Symphony a verified email, and
  the account with that email (`SymphonyElixir.Users`, created on first visit)
  holds what Symphony grants on top of Linear. Everything about *who someone is*
  comes from Linear: the Linear user with the same email decides teams and the
  admin flag. Profiles are re-read from Linear every 10 minutes using Symphony's
  own tracker key, so changes in Linear (new team, removed admin, deactivated
  user) apply without touching Symphony.

  Symphony's own grants add to Linear's: teams someone was given or
  administers, projects, and a global role (`admin` or `global_viewer`). An
  account an admin provisioned ahead of time (`SymphonyElixir.Users.Import`)
  may sign in even when Linear has no user with its email, with only those
  grants; anyone else must be in the Linear workspace, and a deactivated Linear
  user is always refused.

  Modes:

    * `:local` - no sign-in; the local operator has full control. The default
      when the server binds to a loopback address.
    * `:iap` - IAP sign-in. The default for any other address.

  `server.auth: local | iap` overrides the default (`accounts` is the old name
  for `iap`).
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Users}
  alias SymphonyElixir.Linear.Client

  @table :symphony_auth_cache
  @profile_ttl_ms 600_000
  # Failed lookups are remembered briefly so pages can't hammer Linear.
  @negative_ttl_ms 60_000

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
    @public_fields [
      :id,
      :username,
      :name,
      :email,
      :avatar_url,
      :admin,
      :global_viewer,
      :guest,
      :local,
      :teams,
      :team_admin,
      :projects
    ]
    @derive {Jason.Encoder, only: @public_fields}
    defstruct [
      :id,
      :username,
      :name,
      :email,
      :avatar_url,
      :linear_user_id,
      admin: false,
      global_viewer: false,
      guest: false,
      local: false,
      teams: [],
      team_admin: [],
      projects: []
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            username: String.t() | nil,
            name: String.t(),
            email: String.t() | nil,
            avatar_url: String.t() | nil,
            linear_user_id: String.t() | nil,
            admin: boolean(),
            global_viewer: boolean(),
            guest: boolean(),
            local: boolean(),
            teams: [%{id: String.t() | nil, key: String.t(), name: String.t() | nil}],
            team_admin: [String.t()],
            projects: [String.t()]
          }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec mode(map() | nil) :: :local | :iap
  def mode(settings \\ nil) do
    settings = settings || Config.settings!()

    case settings.server.auth do
      auth when auth in ["iap", "accounts"] -> :iap
      "local" -> :local
      _ -> if loopback?(settings.server.host), do: :local, else: :iap
    end
  end

  @doc """
  The IAP audiences signed headers must carry (`server.iap_audiences`).
  """
  @spec iap_audiences() :: [String.t()]
  def iap_audiences, do: Config.settings!().server.iap_audiences || []

  @doc """
  The email to act as when no IAP audience is configured: `SYMPHONY_DEV_USER`,
  for running the dashboard on a laptop. Ignored once an audience is set, so it
  can't open a deployed Symphony.
  """
  @spec dev_user() :: String.t() | nil
  def dev_user do
    case {iap_audiences(), System.get_env("SYMPHONY_DEV_USER")} do
      {[], email} when is_binary(email) and email != "" -> String.downcase(String.trim(email))
      _ -> nil
    end
  end

  @spec local_user() :: User.t()
  def local_user, do: %User{id: "local", name: "Local operator", admin: true, local: true}

  @doc """
  The user for an email IAP verified. The account is created on first visit;
  the Linear workspace still decides whether the person may use Symphony,
  unless an admin provisioned the account.
  """
  @spec user_for_email(String.t()) :: {:ok, User.t()} | {:error, atom()}
  def user_for_email(email) when is_binary(email) do
    with :ok <- linear_member(email),
         {:ok, account} <- Users.ensure(email) do
      user_for_id(account.id)
    end
  end

  # An email Linear doesn't know (or has deactivated) gets no account, unless
  # the account was provisioned. Linear being unreachable doesn't lock people
  # out; user_for_account/1 then gives only Symphony's grants.
  defp linear_member(email) do
    case linear_profile(email) do
      {:ok, %{"active" => false}} -> {:error, :inactive_user}
      {:error, :not_in_workspace} = refused -> if provisioned?(Users.get_by_email(email)), do: :ok, else: refused
      _member_skip_or_unreachable -> :ok
    end
  end

  defp provisioned?(%{imported_at: at}) when is_binary(at), do: true
  defp provisioned?(_account), do: false

  @doc """
  Resolves the session's account id to a user with current Linear permissions.
  """
  @spec user_for_id(String.t() | nil, pos_integer() | nil) :: {:ok, User.t()} | {:error, atom()}
  def user_for_id(account_id, session_version \\ nil) do
    case Users.get(account_id) do
      # Disabling bumps the version and ends older sessions.
      %{session_version: version} when is_integer(session_version) and version != session_version ->
        {:error, :signed_out}

      %{status: "active"} = account ->
        user_for_account(account)

      %{status: "disabled"} ->
        {:error, :disabled}

      _ ->
        {:error, :signed_out}
    end
  end

  @spec user_for_account(map()) :: {:ok, User.t()} | {:error, atom()}
  def user_for_account(account) do
    role = Map.get(account, :role)

    base = %User{
      id: account.id,
      username: account.username,
      name: account.username,
      email: account.email,
      # The bootstrap account stays an admin so a fresh install can approve people.
      admin: account.bootstrap_admin or role == "admin",
      global_viewer: role == "global_viewer"
    }

    case linear_profile(account.email) do
      {:ok, %{"active" => false}} ->
        {:error, :inactive_user}

      {:ok, member} ->
        {:ok, base |> with_linear_member(member) |> with_grants(account)}

      :skip ->
        {:ok, with_grants(base, account)}

      {:error, :not_in_workspace} ->
        if provisioned?(account), do: {:ok, with_grants(base, account)}, else: {:error, :not_in_workspace}

      {:error, _reason} ->
        # Linear unreachable: keep the person signed in with only the access
        # Symphony granted, rather than locking everyone out.
        {:ok, with_grants(base, account)}
    end
  end

  # Symphony's grants add to Linear: teams someone administers or was given
  # access to count as their teams, and project access is kept separately.
  # Any grant lifts Linear's guest read-only status.
  defp with_grants(user, account) do
    team_admin = Map.get(account, :team_admin) || []
    access = Map.get(account, :access) || []
    {project_scopes, team_access} = Enum.split_with(access, &String.starts_with?(&1, "project:"))
    known = MapSet.new(user.teams, & &1.key)

    granted =
      (team_admin ++ team_access)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.map(&%{id: nil, key: &1, name: nil})

    %{
      user
      | teams: user.teams ++ granted,
        team_admin: team_admin,
        projects: Enum.map(project_scopes, &String.replace_prefix(&1, "project:", "")),
        guest: user.guest and team_admin == [] and access == []
    }
  end

  defp with_linear_member(base, member) do
    teams =
      (get_in(member, ["teams", "nodes"]) || [])
      |> Enum.map(&%{id: &1["id"], key: &1["key"], name: &1["name"]})

    %{
      base
      | name: member["displayName"] || member["name"] || base.username,
        avatar_url: member["avatarUrl"],
        linear_user_id: member["id"],
        admin: base.admin or member["admin"] == true,
        guest: member["guest"] == true and not base.admin,
        teams: teams
    }
  end

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
    SymphonyElixir.Iap.create_table()
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
        if is_atom(cached), do: {:error, cached}, else: {:ok, cached}

      true ->
        case client().graphql(@member_query, %{email: email}, []) do
          {:ok, %{"data" => %{"users" => %{"nodes" => [member | _]}}}} ->
            cache_put(key, member)
            {:ok, member}

          {:ok, %{"data" => %{"users" => %{"nodes" => []}}}} ->
            cache_put(key, :not_in_workspace, @negative_ttl_ms)
            {:error, :not_in_workspace}

          other ->
            Logger.warning("Linear member lookup failed: #{inspect(other, limit: 5)}")
            cache_put(key, :linear_unavailable, @negative_ttl_ms)
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

  defp cache_put(key, value, ttl_ms \\ @profile_ttl_ms) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {key, value, System.monotonic_time(:millisecond) + ttl_ms})
    end

    :ok
  end

  defp loopback?(host) when host in ["127.0.0.1", "::1", "localhost"], do: true
  defp loopback?("127." <> _rest), do: true
  defp loopback?(_host), do: false

  defp client, do: Application.get_env(:symphony_elixir, :linear_client_module, Client)
end
