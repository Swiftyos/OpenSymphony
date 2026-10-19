defmodule SymphonyElixirWeb.Visibility do
  @moduledoc """
  Trims dashboard and API payloads to what a person may see.

  Admins, the local operator, and API-token clients see everything. Everyone
  else only sees issues, sessions, and spend from their own Linear teams, and
  never sees host details (workspace paths, worker hosts, agent accounts).
  """

  alias SymphonyElixir.Auth

  @host_fields [:workspace_path, :worker_host, :account, :account_id, :account_email, :account_credential_kind, :session_id]

  @spec filter_payload(map(), Auth.User.t() | nil) :: map()
  def filter_payload(%{error: _} = payload, _user), do: payload

  def filter_payload(payload, user) do
    case visible_teams(user) do
      :all -> payload
      teams -> restrict(payload, MapSet.new(teams))
    end
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
    |> Map.update(:projects, [], fn projects ->
      Enum.map(projects, &Map.update(&1, :issues, [], fn issues -> Enum.filter(issues, fn i -> visible?.(i[:issue_identifier]) end) end))
    end)
    |> Map.put(:accounts, [])
    |> Map.update(:factory, nil, &restrict_factory(&1, visible?))
    |> then(fn p -> Map.put(p, :counts, %{running: length(p.running), retrying: length(p.retrying)}) end)
  end

  defp restrict_factory(nil, _visible?), do: nil

  defp restrict_factory(factory, visible?) do
    nodes =
      Enum.map(factory.flow.nodes, fn node ->
        issues = Enum.filter(node.issues, &visible?.(&1.issue))
        %{node | issues: issues, count: length(issues), running: Enum.count(issues, & &1.backend)}
      end)

    %{factory | usage: Enum.filter(factory.usage, &visible?.(&1.issue)), flow: %{factory.flow | nodes: nodes}}
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
