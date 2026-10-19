defmodule SymphonyElixirWeb.FactoryPresenter do
  @moduledoc """
  Shapes the usage ledger and live sessions into the compact payload behind the
  dashboard's factory diagram and cost explorer.

  The browser receives this once per orchestrator update and does all grouping,
  filtering, and hover work client-side, so interactions never wait on a server
  round-trip.
  """

  alias SymphonyElixir.{FactoryControls, UsageLedger}

  # Fixed harness order: color follows the harness, never its rank.
  @harnesses ["codex", "claude", "opencode"]

  @nodes [
    %{id: "todo", label: "Todo", state: "Todo"},
    %{id: "implement", label: "Implement", state: "In Progress"},
    %{id: "review", label: "In Review", state: "In Review"},
    %{id: "rework", label: "Rework", state: "In Progress"},
    %{id: "merge", label: "Merge", state: "In Progress"},
    %{id: "blocked", label: "Blocked", state: "In Progress"},
    %{id: "done", label: "Done", state: "Done"}
  ]

  # The designed paths of the factory. Observed transitions outside this list
  # are still reported (as `expected: false`) so surprises are visible.
  @expected_edges [
    {"todo", "implement"},
    {"implement", "review"},
    {"review", "merge"},
    {"review", "rework"},
    {"review", "implement"},
    {"rework", "implement"},
    {"rework", "review"},
    {"merge", "done"},
    {"implement", "blocked"},
    {"blocked", "implement"},
    {"merge", "blocked"},
    {"blocked", "review"},
    {"merge", "review"}
  ]

  @spec payload([map()], map()) :: map()
  def payload(running, settings) do
    ledger = UsageLedger.snapshot()
    pricing = Map.get(settings, :pricing) || %{}
    running_by_issue = Map.new(running, &{&1.issue_identifier, &1})

    %{
      harnesses: @harnesses,
      capacity: settings.agent.max_concurrent_agents,
      controls: FactoryControls.all(),
      controls_enabled: controls_enabled?(settings),
      defaults: %{backend: settings.agent.backend, effort: settings.agent.default_effort},
      priced: map_size(pricing) > 0,
      usage: Enum.map(ledger.usage, &price_row(&1, pricing)),
      flow: flow_payload(ledger.flow, running_by_issue)
    }
  end

  @doc """
  `server.controls: false` makes the dashboard read-only for everyone. Otherwise
  each action is allowed per signed-in user (see `SymphonyElixir.Auth`).
  """
  @spec controls_enabled?(map()) :: boolean()
  def controls_enabled?(settings), do: settings.server.controls != false

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

  defp flow_payload(%{edges: edges, issues: issues}, running_by_issue) do
    node_ids = MapSet.new(@nodes, & &1.id)

    issues_by_node =
      issues
      |> Enum.filter(&MapSet.member?(node_ids, &1.node))
      |> Enum.group_by(& &1.node)

    nodes =
      Enum.map(@nodes, fn node ->
        members = Map.get(issues_by_node, node.id, [])

        Map.merge(node, %{
          issues:
            members
            |> Enum.sort_by(& &1.since_ms, :desc)
            |> Enum.take(40)
            |> Enum.map(fn issue ->
              agent = Map.get(running_by_issue, issue.issue)

              %{
                id: issue[:id],
                issue: issue.issue,
                title: issue.title,
                url: issue.url,
                project: issue.project,
                team: issue.team,
                since_ms: issue.since_ms,
                backend: agent && agent.backend
              }
            end),
          count: length(members),
          running: Enum.count(members, &Map.has_key?(running_by_issue, &1.issue))
        })
      end)

    observed = Map.new(edges, &{{&1.from, &1.to}, &1.count})

    expected =
      Enum.map(@expected_edges, fn {from, to} = key ->
        %{from: from, to: to, count: Map.get(observed, key, 0), expected: true}
      end)

    unexpected =
      edges
      |> Enum.reject(&({&1.from, &1.to} in @expected_edges))
      |> Enum.filter(&(MapSet.member?(node_ids, &1.from) and MapSet.member?(node_ids, &1.to)))
      |> Enum.map(&Map.put(&1, :expected, false))

    %{nodes: nodes, edges: expected ++ unexpected}
  end
end
