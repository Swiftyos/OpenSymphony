defmodule SymphonyElixirWeb.FactoryPresenter do
  @moduledoc """
  Shapes the usage ledger and live sessions into the compact payload behind the
  dashboard's factory diagram and cost explorer.

  The browser receives this once per orchestrator update and does all grouping,
  filtering, and hover work client-side, so interactions never wait on a server
  round-trip.
  """

  alias SymphonyElixir.Factory.Store
  alias SymphonyElixir.{IssueStage, UsageLedger}

  # Fixed harness order: color follows the harness, never its rank.
  @harnesses ["codex", "claude", "opencode"]
  @issues_per_stage 40

  @doc """
  `opts[:teams]` adds teams to show even before they have any issues (e.g. the
  viewer's own Linear teams).
  """
  @spec payload([map()], map(), keyword()) :: map()
  def payload(running, settings, opts \\ []) do
    ledger = UsageLedger.snapshot()
    pricing = Map.get(settings, :pricing) || %{}
    running_by_issue = Map.new(running, &{&1.issue_identifier, &1})
    teams = team_keys(ledger.flow.issues, Keyword.get(opts, :teams, []))
    definitions = Map.new(teams, &{&1, Store.get(&1)})

    %{
      harnesses: @harnesses,
      capacity: settings.agent.max_concurrent_agents,
      controls_enabled: controls_enabled?(settings),
      priced: map_size(pricing) > 0,
      usage: Enum.map(ledger.usage, &(&1 |> price_row(pricing) |> Map.update(:url, nil, fn url -> https_url(url) end))),
      team: List.first(teams),
      teams: Enum.map(teams, &%{key: &1, name: if(&1 == Store.default_team(), do: "Default flow"), custom: Store.custom?(&1)}),
      definitions: definitions,
      flows: Map.new(teams, &{&1, team_flow(&1, definitions[&1], ledger.flow, running_by_issue)}),
      linear_states: linear_states(settings, definitions),
      label_prefix: IssueStage.label_prefix(settings)
    }
  end

  # Teams with work, teams with their own flow, and any extra (viewer's) teams.
  # With none at all, show the organisation's default flow.
  defp team_keys(issues, extra) do
    issues
    |> Enum.map(& &1.team)
    |> Kernel.++(Store.teams())
    |> Kernel.++(extra)
    |> Enum.filter(&(is_binary(&1) and &1 != Store.default_team()))
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [] -> [Store.default_team()]
      teams -> teams
    end
  end

  defp team_flow(team, definition, flow, running_by_issue) do
    ids = MapSet.new(definition["stages"], & &1["id"])
    members = flow.issues |> Enum.filter(&(&1.team == team and MapSet.member?(ids, &1.node))) |> Enum.group_by(& &1.node)

    nodes =
      Map.new(ids, fn id ->
        issues = Map.get(members, id, [])

        {id,
         %{
           issues: issues |> Enum.sort_by(& &1.since_ms, :desc) |> Enum.take(@issues_per_stage) |> Enum.map(&issue_row(&1, running_by_issue)),
           count: length(issues),
           running: Enum.count(issues, &Map.has_key?(running_by_issue, &1.issue))
         }}
      end)

    edges =
      flow.edges
      |> Enum.filter(&(&1.team == team and MapSet.member?(ids, &1.from) and MapSet.member?(ids, &1.to)))
      |> Map.new(&{"#{&1.from}>#{&1.to}", &1.count})

    %{nodes: nodes, edges: edges}
  end

  defp issue_row(issue, running_by_issue) do
    agent = Map.get(running_by_issue, issue.issue)

    %{
      id: issue[:id],
      issue: issue.issue,
      title: issue.title,
      url: https_url(issue.url),
      project: issue.project,
      team: issue.team,
      since_ms: issue.since_ms,
      backend: agent && agent.backend
    }
  end

  # Offered as suggestions in the editor's Linear state field.
  defp linear_states(settings, definitions) do
    definitions
    |> Map.values()
    |> Enum.flat_map(fn d -> Enum.map(d["stages"], & &1["linear_state"]) end)
    |> Kernel.++(settings.tracker.active_states ++ ["In Review"] ++ settings.tracker.terminal_states)
    |> Enum.uniq()
  end

  @doc """
  `server.controls: false` makes the dashboard read-only for everyone. Otherwise
  each action is allowed per signed-in user (see `SymphonyElixir.Auth`).
  """
  @spec controls_enabled?(map()) :: boolean()
  def controls_enabled?(settings), do: settings.server.controls != false

  # Stored URLs can come from anywhere; only https ones are sent to the browser.
  defp https_url("https://" <> _rest = url), do: url
  defp https_url(_url), do: nil

  defp price_row(row, pricing) do
    rates = Map.get(pricing, "#{row.backend}/#{row.model}") || Map.get(pricing, row.backend)

    cost =
      case rates do
        %{} ->
          (row.input_tokens * rate(rates, "input_per_mtok") + row.output_tokens * rate(rates, "output_per_mtok")) / 1_000_000

        _ ->
          nil
      end

    Map.put(row, :cost_usd, cost)
  end

  defp rate(rates, key) do
    case Map.get(rates, key) do
      value when is_number(value) -> value
      _ -> 0
    end
  end
end
