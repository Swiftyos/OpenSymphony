defmodule SymphonyElixir.Auth do
  @moduledoc """
  Who is using the dashboard and what they may do.

  Google Identity-Aware Proxy in front of the dashboard signs people in; the
  signed IAP header (`SymphonyElixir.Iap`) gives Symphony a verified email, and
  the account with that email (`SymphonyElixir.Users`, created on first visit)
  holds what Symphony grants on top of Linear. Everything about *who someone is*
  comes from Linear: the Linear user with the same email decides teams and the
  admin flag. Profiles are re-read from Linear every 10 minutes using Symphony's
  own tracker key, so changes in Linear (new team, removed admin, deactivated
  user) apply without touching Symphony.

  Modes:

    * `:local` - no sign-in; the local operator has full control. The default
      when the server binds to a loopback address.
    * `:iap` - IAP sign-in. The default for any other address.

  `server.auth: local | iap` overrides the default (`accounts` is the old name
  for `iap`).
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, UsageLedger, Users}
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
    @public_fields [:id, :username, :name, :email, :avatar_url, :admin, :guest, :local, :teams, :team_admin, :projects]
    @derive {Jason.Encoder, only: @public_fields}
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
  the Linear workspace still decides whether the person may use Symphony.
  """
  @spec user_for_email(String.t()) :: {:ok, User.t()} | {:error, atom()}
  def user_for_email(email) when is_binary(email) do
    with :ok <- linear_member(email),
         {:ok, account} <- Users.ensure(email) do
      user_for_id(account.id)
    end
  end

  # An email Linear doesn't know (or has deactivated) gets no account. Linear
  # being unreachable doesn't lock people out; user_for_account/1 then gives
  # only Symphony's grants.
  defp linear_member(email) do
    case linear_profile(email) do
      {:ok, %{"active" => false}} -> {:error, :inactive_user}
      {:error, :not_in_workspace} -> {:error, :not_in_workspace}
      _member_skip_or_unreachable -> :ok
    end
  end

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
        {:ok, base |> with_linear_member(member, account.bootstrap_admin) |> with_grants(account)}

      :skip ->
        {:ok, with_grants(base, account)}

      {:error, :not_in_workspace} ->
        {:error, :not_in_workspace}

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
  Like `can_move?/2`, but also allows issues in projects the user was given
  access to.
  """
  @spec can_move_issue?(User.t() | nil, String.t() | nil, String.t() | nil) :: boolean()
  def can_move_issue?(user, identifier, project_slug) do
    can_move?(user, identifier) or (is_binary(project_slug) and project_slug in movable_projects(user))
  end

  @doc """
  Whether the user may send a message to the agent working on an issue (by
  identifier) from the dashboard: the same people who may move it. `nil` is an
  API-token client, which has full access.
  """
  @spec can_message_agent?(User.t() | nil, String.t() | nil) :: boolean()
  def can_message_agent?(nil, _identifier), do: true
  def can_message_agent?(user, identifier), do: can_move?(user, identifier)

  @doc """
  Whether the user may change factory-wide stage controls and approve accounts.
  """
  @spec can_control?(User.t() | nil) :: boolean()
  def can_control?(%User{local: true}), do: true
  def can_control?(%User{admin: true}), do: true
  def can_control?(_user), do: false

  @doc """
  Whether the user may edit a flow and its stage controls: admins any flow
  (including the organisation default), members their own teams' flows and the
  flows of projects their teams work in. Guests never.
  """
  @spec can_edit_factory?(User.t() | nil, String.t() | nil) :: boolean()
  def can_edit_factory?(%User{local: true}, _team), do: true
  def can_edit_factory?(%User{admin: true}, _team), do: true
  def can_edit_factory?(%User{guest: true}, _team), do: false

  # A project's flow: people given the project, and members of any team whose
  # issues are in it.
  def can_edit_factory?(%User{teams: teams, projects: projects}, "project:" <> slug) do
    slug in projects or Enum.any?(teams, &(&1.key in project_teams(slug)))
  end

  def can_edit_factory?(%User{teams: teams}, team) when is_binary(team), do: Enum.any?(teams, &(&1.key == team))
  def can_edit_factory?(_user, _team), do: false

  @doc """
  Team keys whose issues the user may move; `:all` for admins and local operators.
  """
  @spec movable_teams(User.t() | nil) :: :all | [String.t()]
  def movable_teams(%User{local: true}), do: :all
  def movable_teams(%User{admin: true}), do: :all
  def movable_teams(%User{guest: true}), do: []
  def movable_teams(%User{teams: teams}), do: Enum.map(teams, & &1.key)
  def movable_teams(_user), do: []

  @doc """
  Project slugs whose issues the user may move through a project grant.
  """
  @spec movable_projects(User.t() | nil) :: [String.t()]
  def movable_projects(%User{guest: false, projects: projects}), do: projects
  def movable_projects(_user), do: []

  @doc """
  Whether the user may open the Users page to manage access: admins, and admins
  of at least one team.
  """
  @spec can_manage_access?(User.t() | nil) :: boolean()
  def can_manage_access?(%User{team_admin: [_ | _]}), do: true
  def can_manage_access?(user), do: can_control?(user)

  @doc """
  Whether the user may grant or revoke access to a scope: admins any team or
  project, team admins their teams and the projects their teams work in.
  """
  @spec can_grant?(User.t() | nil, String.t()) :: boolean()
  def can_grant?(%User{team_admin: [_ | _] = admin_of} = user, "project:" <> slug) do
    can_control?(user) or Enum.any?(project_teams(slug), &(&1 in admin_of))
  end

  def can_grant?(%User{team_admin: admin_of} = user, scope) when is_binary(scope), do: can_control?(user) or scope in admin_of
  def can_grant?(user, _scope), do: can_control?(user)

  defp project_teams(slug), do: get_in(UsageLedger.projects(), [slug, :teams]) || []

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
