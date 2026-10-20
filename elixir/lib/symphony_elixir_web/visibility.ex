defmodule SymphonyElixirWeb.Visibility do
  @moduledoc """
  Trims dashboard and API payloads to what a person may see.

  Admins, the local operator, and API-token clients see everything. Everyone
  else only sees issues, sessions, and spend from their own Linear teams, and
  never sees host details (workspace paths, worker hosts, agent accounts).
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
      teams -> restrict(payload, MapSet.new(teams))
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
    visible? = fn identifier -> MapSet.member?(teams, team(identifier)) end

    payload
    |> Map.update(:running, [], &Enum.filter(&1, fn e -> visible?.(e.issue_identifier) end))
    |> Map.update(:retrying, [], &Enum.filter(&1, fn e -> visible?.(e.issue_identifier) end))
    |> Map.update(:projects, [], &team_projects(&1, visible?))
    |> Map.update(:factory, nil, &restrict_factory(&1, visible?, teams))
    |> then(fn p -> Map.put(p, :counts, %{running: length(p.running), retrying: length(p.retrying)}) end)
  end

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

  defp restrict(payload, teams) do
    visible? = fn identifier -> MapSet.member?(teams, team(identifier)) end

    payload
    |> Map.update(:running, [], &(&1 |> Enum.filter(fn e -> visible?.(e.issue_identifier) end) |> Enum.map(fn e -> drop_host_fields(e) end)))
    |> Map.update(:retrying, [], &(&1 |> Enum.filter(fn e -> visible?.(e.issue_identifier) end) |> Enum.map(fn e -> drop_host_fields(e) end)))
    |> Map.update(:projects, [], fn projects -> Enum.map(projects, &restrict_project_issues(&1, visible?)) end)
    |> Map.put(:accounts, [])
    |> Map.update(:factory, nil, &restrict_factory(&1, visible?, teams))
    |> then(fn p -> Map.put(p, :counts, %{running: length(p.running), retrying: length(p.retrying)}) end)
  end

  # Projects with work but none of it this team's are left out.
  defp team_projects(projects, visible?) do
    Enum.flat_map(projects, fn project ->
      issues = Map.get(project, :issues, [])
      kept = Enum.filter(issues, &visible?.(&1[:issue_identifier]))
      if issues != [] and kept == [], do: [], else: [Map.put(project, :issues, kept)]
    end)
  end

  defp restrict_project_issues(project, visible?) do
    Map.update(project, :issues, [], fn issues -> Enum.filter(issues, fn i -> visible?.(i[:issue_identifier]) end) end)
  end

  defp restrict_factory(nil, _visible?, _teams), do: nil

  defp restrict_factory(factory, visible?, teams) do
    keep = Enum.filter(factory.teams, &visible_flow?(&1, teams))
    keys = Enum.map(keep, & &1.key)

    %{
      factory
      | usage: Enum.filter(factory.usage, &visible?.(&1.issue)),
        teams: keep,
        team: keep |> Enum.find(&(Map.get(&1, :kind) != "project")) |> then(&(&1 && &1.key)),
        definitions: Map.take(factory.definitions, keys),
        flows: factory.flows |> Map.take(keys) |> Map.new(fn {key, flow} -> {key, restrict_flow(flow, visible?)} end)
    }
  end

  # Projects can span teams: show one when any of its teams is the viewer's,
  # with only the viewer's teams' issues on it.
  defp visible_flow?(%{kind: "project", teams: project_teams}, teams), do: Enum.any?(project_teams, &MapSet.member?(teams, &1))
  defp visible_flow?(entry, teams), do: MapSet.member?(teams, entry.key)

  defp restrict_flow(flow, visible?) do
    nodes =
      Map.new(flow.nodes, fn {id, node} ->
        if Enum.all?(node.issues, &visible?.(&1.issue)) do
          {id, node}
        else
          issues = Enum.filter(node.issues, &visible?.(&1.issue))
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
