defmodule SymphonyElixir.Policy do
  @moduledoc """
  What a person may see and do: the one place Symphony decides it. The
  dashboard's LiveViews, the JSON API and the MCP tools all ask here, so a page
  or a tool can't apply its own, different rule. `SymphonyElixir.Auth` says
  *who* someone is (account, Linear profile, grants); this module says what
  that allows.

  Roles:

    * **admin** (global): Linear workspace admins, the bootstrap account, and
      accounts given the `admin` role. Sees and may do everything.
    * **global viewer**: accounts given the `global_viewer` role. Sees
      everything, every team, like an admin, and changes nothing: no move,
      approval, message, flow edit, project change, refresh or access change,
      in the dashboard, the API or MCP. Their own account settings and their
      own MCP token (rotating it) are self-service, not changes to Symphony,
      and stay allowed.
    * **team admin** (per team): a member of the team who also manages who has
      access to it and to the projects it works in.
    * **member** (per team): sees the team's work (issues, sessions, flows,
      usage, traces) and works in it: moves and reviews its issues, messages
      its agents, edits its flow and the flows of projects it works in.
    * **guest**: a Linear guest Symphony gave nothing: sees their teams,
      read-only.

  A person's teams are their Linear teams plus the teams Symphony granted
  (`SymphonyElixir.Users`); someone with no teams sees nothing team-specific.
  Admin outranks global viewer: a Linear admin listed as a viewer stays an
  admin. `nil` is an API-token client (`server.api_token`, role `:api`): it
  sees everything and may use the JSON API's actions (refresh, restart,
  messages), but isn't a person, so it edits no flow and grants nothing.
  """

  alias SymphonyElixir.Auth.User
  alias SymphonyElixir.{LabelSync, UsageLedger}

  @type role :: :admin | :global_viewer | :member | :guest | :api
  @type action ::
          :write
          | :refresh
          | :control
          | :restart
          | :view_users
          | :view_metrics
          | {:view_issue, String.t() | nil, String.t() | nil}
          | {:move_issue, String.t() | nil, String.t() | nil}
          | {:message_agent, String.t() | nil, String.t() | nil}
          | {:edit_flow, String.t() | nil}
          | {:grant, String.t()}

  # LiveView events that only change what the page shows (or the viewer's own
  # settings). Read-only people may send these and nothing else; an event not
  # listed here is refused for them before any page code runs.
  @read_events ~w(
    pick_team pick_range open_trace close_issue
    open_chat close_chat toggle_chat_size toggle_bell close_bell
    sessions_view sessions_filter dismiss_mcp_setup
  )

  @spec role(User.t() | nil) :: role()
  def role(nil), do: :api
  def role(%User{local: true}), do: :admin
  def role(%User{admin: true}), do: :admin
  def role(%User{global_viewer: true}), do: :global_viewer
  def role(%User{guest: true}), do: :guest
  def role(%User{}), do: :member

  @doc "Whether the person sees every team's work (admins and global viewers)."
  @spec sees_all?(User.t() | nil) :: boolean()
  def sees_all?(user), do: role(user) in [:admin, :global_viewer, :api]

  @doc "Whether the person may change nothing at all (global viewers and guests)."
  @spec read_only?(User.t() | nil) :: boolean()
  def read_only?(user), do: role(user) in [:global_viewer, :guest]

  @doc "Team keys whose work the person sees; `:all` for those who see everything."
  @spec visible_teams(User.t() | nil) :: :all | [String.t()]
  def visible_teams(user) do
    if sees_all?(user), do: :all, else: Enum.map(user.teams, & &1.key)
  end

  @doc "Project slugs the person was given on their own (beyond their teams)."
  @spec visible_projects(User.t() | nil) :: :all | [String.t()]
  def visible_projects(user), do: if(sees_all?(user), do: :all, else: user.projects || [])

  @doc """
  Team keys whose issues the person may move; `:all` for admins. Read-only
  people get none.
  """
  @spec movable_teams(User.t() | nil) :: :all | [String.t()]
  def movable_teams(user) do
    cond do
      is_nil(user) or read_only?(user) -> []
      sees_all?(user) -> :all
      true -> Enum.map(user.teams, & &1.key)
    end
  end

  @doc "Project slugs whose issues the person may move through a project grant."
  @spec movable_projects(User.t() | nil) :: [String.t()]
  def movable_projects(%User{} = user), do: if(read_only?(user), do: [], else: user.projects || [])
  def movable_projects(_user), do: []

  @spec can?(User.t() | nil, action()) :: boolean()
  def can?(user, action), do: authorize(user, action) == :ok

  @doc """
  `:ok`, or `{:error, reason}` with a reason `describe/1` (and
  `SymphonyElixir.IssueMoves.describe_error/1`) can put into words.
  """
  @spec authorize(User.t() | nil, action()) :: :ok | {:error, atom()}
  def authorize(user, {:view_issue, identifier, project}), do: check(issue_visible?(user, identifier, project), :not_found)
  def authorize(user, :view_metrics), do: check(sees_all?(user), :not_allowed)
  def authorize(%User{} = user, :view_users), do: check(sees_all?(user) or team_admin_of(user) != [], :not_allowed)
  def authorize(nil, :view_users), do: {:error, :not_allowed}

  def authorize(user, action) do
    if read_only?(user), do: {:error, :read_only}, else: authorize_change(user, action)
  end

  defp authorize_change(_user, action) when action in [:write, :refresh], do: :ok
  defp authorize_change(nil, :restart), do: :ok
  defp authorize_change(nil, {:message_agent, _identifier, _project}), do: :ok
  defp authorize_change(nil, _action), do: {:error, :not_allowed}
  defp authorize_change(user, action) when action in [:control, :restart], do: check(role(user) == :admin, :not_admin)

  defp authorize_change(user, {:move_issue, identifier, project}),
    do: check(role(user) == :admin or in_teams?(user, identifier) or granted_project?(user, project), :not_team_member)

  defp authorize_change(user, {:message_agent, identifier, project}),
    do: check(role(user) == :admin or in_teams?(user, identifier) or granted_project?(user, project), :not_team_member)

  defp authorize_change(user, {:edit_flow, scope}), do: check(role(user) == :admin or flow_member?(user, scope), :not_team_editor)
  defp authorize_change(user, {:grant, scope}), do: check(role(user) == :admin or team_admin_for?(user, scope), :not_team_admin)
  defp authorize_change(_user, _action), do: {:error, :not_allowed}

  defp check(true, _reason), do: :ok
  defp check(_false, reason), do: {:error, reason}

  @doc "Whether a LiveView event may run for this person (see `@read_events`)."
  @spec event_allowed?(User.t() | nil, String.t()) :: boolean()
  def event_allowed?(user, event), do: not read_only?(user) or event in @read_events

  @spec describe(atom()) :: String.t()
  def describe(:read_only), do: "Your access is read-only: you can see this but not change it."
  def describe(:not_admin), do: "Only admins can do that."
  def describe(:not_team_admin), do: "You can only give access to teams you administer and their projects."
  def describe(:not_team_member), do: "You can only change issues from your own teams."
  def describe(:not_team_editor), do: "Only this team's members and admins can change its flow."
  def describe(:not_found), do: "Not found."
  def describe(_reason), do: "You aren't allowed to do that."

  @doc """
  Whether the person sees an issue: by its team (the identifier's prefix), or
  by a project they were given.
  """
  @spec issue_visible?(User.t() | nil, String.t() | nil, String.t() | nil) :: boolean()
  def issue_visible?(user, identifier, project \\ nil) do
    sees_all?(user) or in_teams?(user, identifier) or granted_project?(user, project)
  end

  @doc """
  Whether the person sees a Linear project (its settings, its flow): one of
  their teams works in it (by the issues Symphony saw, or Linear's own project
  teams), or they were given it.
  """
  @spec project_visible?(User.t() | nil, String.t()) :: boolean()
  def project_visible?(user, slug) do
    sees_all?(user) or granted_project?(user, slug) or
      Enum.any?(project_teams(slug) ++ Map.get(LabelSync.project_teams(), slug, []), &in_team_keys?(user, &1))
  end

  defp in_team_keys?(%User{teams: teams}, key), do: Enum.any?(teams, &(&1.key == key))
  defp in_team_keys?(_user, _key), do: false

  @doc "Teams the person administers (Symphony grants), for the Users page."
  @spec team_admin_of(User.t() | nil) :: [String.t()]
  def team_admin_of(%User{} = user), do: if(read_only?(user), do: [], else: user.team_admin || [])
  def team_admin_of(_user), do: []

  @doc "The team key of an identifier such as `PAY-12`."
  @spec team_of(String.t() | nil) :: String.t() | nil
  def team_of(identifier) when is_binary(identifier) do
    case String.split(identifier, "-", parts: 2) do
      [key, _number] -> key
      _ -> nil
    end
  end

  def team_of(_identifier), do: nil

  defp in_teams?(%User{teams: teams}, identifier) do
    case team_of(identifier) do
      nil -> false
      key -> Enum.any?(teams, &(&1.key == key))
    end
  end

  defp in_teams?(_user, _identifier), do: false

  defp granted_project?(%User{projects: projects}, project) when is_binary(project), do: project in (projects || [])
  defp granted_project?(_user, _project), do: false

  # A project's flow: people given the project, and members of any team whose
  # issues are in it. A team's flow: its members. The default flow: admins.
  defp flow_member?(%User{} = user, "project:" <> slug) do
    slug in (user.projects || []) or Enum.any?(user.teams, &(&1.key in project_teams(slug)))
  end

  defp flow_member?(%User{teams: teams}, team) when is_binary(team), do: Enum.any?(teams, &(&1.key == team))
  defp flow_member?(_user, _scope), do: false

  # Team admins grant their teams and the projects their teams work in.
  defp team_admin_for?(user, "project:" <> slug), do: Enum.any?(project_teams(slug), &(&1 in team_admin_of(user)))
  defp team_admin_for?(user, scope) when is_binary(scope), do: scope in team_admin_of(user)
  defp team_admin_for?(_user, _scope), do: false

  defp project_teams(slug), do: get_in(UsageLedger.projects(), [slug, :teams]) || []
end
