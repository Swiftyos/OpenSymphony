defmodule SymphonyElixirWeb.Visibility do
  @moduledoc """
  Trims dashboard and API payloads to what a person may see.

  Admins, the local operator, and API-token clients see everything. Everyone
  else only sees issues, sessions, and spend from their teams (Linear teams
  plus teams Symphony gave them) and projects they were given, and never sees
  host details (workspace paths, worker hosts, agent accounts).
  """

  alias SymphonyElixir.Auth

  @host_fields [
    :workspace_path,
    :worker_host,
    :account,
    :account_id,
    :account_email,
    :account_credential_kind,
    :session_id
  ]

  @spec filter_payload(map(), Auth.User.t() | nil) :: map()
  def filter_payload(%{error: _} = payload, _user), do: payload

  def filter_payload(payload, user) do
    case visible_teams(user) do
      :all -> payload
      teams -> restrict(payload, MapSet.new(teams), user.projects)
    end
  end

  @doc """
  Narrows an already-filtered payload to one team's work: its issues, sessions,
  spend, its flow and the flows of projects it works in. Unlike
  `filter_payload/2` this is a view choice, not a permission, so host details
  and agent accounts stay.
  """
  @spec scope_to_team(map(), String.t() | nil) :: map()
  def scope_to_team(%{error: _} = payload, _team), do: payload
  def scope_to_team(payload, nil), do: payload

  def scope_to_team(payload, team) when is_binary(team) do
    teams = MapSet.new([team])
    visible? = visible_fun(teams, [])

    payload
    |> update_sessions(&Enum.filter(&1, fn e -> visible?.(e.issue_identifier, nil) end))
    |> Map.update(:projects, [], &team_projects(&1, visible?))
    |> Map.update(:factory, nil, &restrict_factory(&1, visible?, teams, []))
    |> put_counts()
  end

  @doc """
  Narrows an already-filtered payload to one project's work: its sessions,
  spend and flow, whichever teams its issues belong to. A view choice, like
  `scope_to_team/2`.
  """
  @spec scope_to_project(map(), String.t() | nil) :: map()
  def scope_to_project(%{error: _} = payload, _slug), do: payload
  def scope_to_project(payload, nil), do: payload

  def scope_to_project(payload, slug) when is_binary(slug) do
    in_project? = fn e -> Map.get(e, :project_slug) == slug end

    payload
    |> update_sessions(&Enum.filter(&1, in_project?))
    |> Map.update(:projects, [], &Enum.filter(&1, fn project -> project[:slug] == slug end))
    |> Map.update(:factory, nil, &project_factory(&1, slug))
    |> put_counts()
  end

  @doc """
  The sessions (live or ended entries) a person may see, without host details
  unless they see everything. Like `filter_payload/2`, for a bare list.
  """
  @spec filter_sessions([map()], Auth.User.t() | nil) :: [map()]
  def filter_sessions(sessions, user) do
    case visible_teams(user) do
      :all ->
        sessions

      teams ->
        visible? = visible_fun(MapSet.new(teams), user.projects)
        for e <- sessions, visible?.(e.issue_identifier, Map.get(e, :project_slug)), do: drop_host_fields(e)
    end
  end

  @doc "Sessions narrowed to one project, else one team, else left alone."
  @spec scope_sessions([map()], String.t() | nil, String.t() | nil) :: [map()]
  def scope_sessions(sessions, _team, project) when is_binary(project), do: Enum.filter(sessions, &(Map.get(&1, :project_slug) == project))
  def scope_sessions(sessions, team, _project) when is_binary(team), do: Enum.filter(sessions, &(team(&1.issue_identifier) == team))
  def scope_sessions(sessions, _team, _project), do: sessions

  @spec filter_issue(map(), Auth.User.t() | nil, String.t()) :: {:ok, map()} | :hidden
  def filter_issue(payload, user, identifier) do
    case visible_teams(user) do
      :all -> {:ok, payload}
      teams -> if team(identifier) in teams, do: {:ok, drop_host_fields(payload)}, else: :hidden
    end
  end

  # nil = API-token client: full access, like before sign-in existed.
  defp visible_teams(nil), do: :all
  defp visible_teams(%Auth.User{local: true}), do: :all
  defp visible_teams(%Auth.User{admin: true}), do: :all
  defp visible_teams(%Auth.User{teams: teams}), do: Enum.map(teams, & &1.key)

  # An issue is visible when its team is, or its project was granted.
  defp visible_fun(teams, projects) do
    fn identifier, project -> MapSet.member?(teams, team(identifier)) or project in projects end
  end

  defp restrict(payload, teams, projects) do
    visible? = visible_fun(teams, projects)
    entry_visible? = fn e -> visible?.(e.issue_identifier, Map.get(e, :project_slug)) end

    payload
    |> update_sessions(&(&1 |> Enum.filter(entry_visible?) |> Enum.map(fn e -> drop_host_fields(e) end)))
    |> Map.update(:projects, [], fn list -> Enum.map(list, &restrict_project_issues(&1, visible?)) end)
    |> Map.put(:accounts, [])
    |> Map.update(:factory, nil, &restrict_factory(&1, visible?, teams, projects))
    |> put_counts()
  end

  # Live sessions, and ended ones when the payload carries them (the dashboard
  # adds `completed`; the state API doesn't).
  defp update_sessions(payload, fun) do
    payload
    |> Map.update(:running, [], fun)
    |> Map.update(:retrying, [], fun)
    |> then(fn p -> if Map.has_key?(p, :completed), do: Map.update!(p, :completed, fun), else: p end)
  end

  defp put_counts(payload), do: Map.put(payload, :counts, %{running: length(payload.running), retrying: length(payload.retrying)})

  # Projects with work but none of it this team's are left out.
  defp team_projects(projects, visible?) do
    Enum.flat_map(projects, fn project ->
      issues = Map.get(project, :issues, [])
      kept = Enum.filter(issues, &visible?.(&1[:issue_identifier], project[:slug]))
      if issues != [] and kept == [], do: [], else: [Map.put(project, :issues, kept)]
    end)
  end

  defp restrict_project_issues(project, visible?) do
    Map.update(project, :issues, [], fn issues -> Enum.filter(issues, fn i -> visible?.(i[:issue_identifier], project[:slug]) end) end)
  end

  defp restrict_factory(nil, _visible?, _teams, _projects), do: nil

  defp restrict_factory(factory, visible?, teams, projects) do
    keep = Enum.filter(factory.teams, &visible_flow?(&1, teams, projects))
    keys = Enum.map(keep, & &1.key)

    %{
      factory
      | usage: Enum.filter(factory.usage, &visible?.(&1.issue, &1[:project])),
        teams: keep,
        team: keep |> Enum.find(&(Map.get(&1, :kind) != "project")) |> then(&(&1 && &1.key)),
        definitions: Map.take(factory.definitions, keys),
        flows: factory.flows |> Map.take(keys) |> Map.new(fn {key, flow} -> {key, restrict_flow(flow, visible?)} end)
    }
  end

  # Only the project's own entry; its flow already holds only its issues.
  defp project_factory(nil, _slug), do: nil

  defp project_factory(factory, slug) do
    keep = Enum.filter(factory.teams, &(Map.get(&1, :kind) == "project" and &1.slug == slug))
    keys = Enum.map(keep, & &1.key)

    %{
      factory
      | usage: Enum.filter(factory.usage, &(&1[:project] == slug)),
        teams: keep,
        team: List.first(keys),
        definitions: Map.take(factory.definitions, keys),
        flows: Map.take(factory.flows, keys)
    }
  end

  # Projects can span teams: show one when it was granted or any of its teams
  # is the viewer's, with only the issues they may see on it.
  defp visible_flow?(%{kind: "project"} = entry, teams, projects),
    do: entry.slug in projects or Enum.any?(entry.teams, &MapSet.member?(teams, &1))

  defp visible_flow?(entry, teams, _projects), do: MapSet.member?(teams, entry.key)

  defp restrict_flow(flow, visible?) do
    nodes =
      Map.new(flow.nodes, fn {id, node} ->
        if Enum.all?(node.issues, &visible?.(&1.issue, &1.project)) do
          {id, node}
        else
          issues = Enum.filter(node.issues, &visible?.(&1.issue, &1.project))
          {id, %{node | issues: issues, count: length(issues), running: Enum.count(issues, & &1.backend)}}
        end
      end)

    %{flow | nodes: nodes}
  end

  defp drop_host_fields(entry) when is_map(entry), do: Map.drop(entry, @host_fields)

  defp team(identifier) when is_binary(identifier) do
    case String.split(identifier, "-", parts: 2) do
      [key, _number] -> key
      _ -> nil
    end
  end

  defp team(_identifier), do: nil
end
