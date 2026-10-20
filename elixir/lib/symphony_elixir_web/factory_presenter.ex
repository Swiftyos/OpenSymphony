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

  `teams` lists every flow the viewer can pick: teams (or `DEFAULT`) and then
  projects (`project:<slug>`). `definitions` and `flows` are keyed the same way.
  A project without its own flow shows the flow of the team most of its issues
  belong to.
  """
  @spec payload([map()], map(), keyword()) :: map()
  def payload(running, settings, opts \\ []) do
    ledger = UsageLedger.snapshot()
    pricing = Map.get(settings, :pricing) || %{}
    running_by_issue = Map.new(running, &{&1.issue_identifier, &1})
    teams = team_keys(ledger.flow.issues, Keyword.get(opts, :teams, []))
    projects = project_entries(settings)
    own_flow = MapSet.new(Store.projects())

    definitions =
      Map.new(teams, &{&1, Store.get(&1)})
      |> Map.merge(Map.new(projects, &{&1.key, Store.get(&1.key, List.first(&1.teams))}))

    team_flows = Map.new(teams, &{&1, team_flow(&1, definitions[&1], ledger.flow, running_by_issue, own_flow)})
    project_flows = Map.new(projects, &{&1.key, project_flow(&1.slug, definitions[&1.key], ledger.flow, running_by_issue)})

    %{
      harnesses: @harnesses,
      # The model each harness runs (from its config), shown next to the harness.
      harness_models: Map.new(@harnesses, &{&1, UsageLedger.model_label(&1)}),
      capacity: settings.agent.max_concurrent_agents,
      controls_enabled: controls_enabled?(settings),
      priced: map_size(pricing) > 0,
      usage: Enum.map(ledger.usage, &(&1 |> price_row(pricing) |> Map.update(:url, nil, fn url -> https_url(url) end))),
      team: List.first(teams),
      teams:
        Enum.map(teams, &%{key: &1, kind: team_kind(&1), name: if(&1 == Store.default_team(), do: "Default flow"), custom: Store.custom?(&1)}) ++
          Enum.map(projects, &Map.take(&1, [:key, :kind, :name, :slug, :teams, :custom])),
      definitions: definitions,
      flows: Map.merge(team_flows, project_flows),
      linear_states: linear_states(settings, definitions),
      label_prefix: IssueStage.label_prefix(settings),
      approval_label: IssueStage.approval_label(settings)
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

  defp team_kind(key), do: if(key == Store.default_team(), do: "default", else: "team")

  # Configured projects, projects with work, and projects with their own flow.
  defp project_entries(settings) do
    seen = UsageLedger.projects()
    linear_names = SymphonyElixir.LabelSync.project_names()

    settings.tracker.projects
    |> List.wrap()
    |> Enum.map(& &1.slug)
    |> Kernel.++(Map.keys(seen))
    |> Kernel.++(Store.projects())
    |> Enum.filter(&(is_binary(&1) and is_binary(Store.project_scope(&1))))
    |> Enum.uniq()
    |> Enum.map(fn slug ->
      info = Map.get(seen, slug, %{name: nil, teams: []})
      key = Store.project_scope(slug)
      name = info.name || linear_names[slug] || slug
      %{key: key, kind: "project", slug: slug, name: name, teams: info.teams, custom: Store.custom?(key)}
    end)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  # A team's diagram leaves out issues whose project follows its own flow.
  defp team_flow(team, definition, flow, running_by_issue, own_flow) do
    stage_flow(
      definition,
      Enum.filter(flow.issues, &(&1.team == team and not MapSet.member?(own_flow, &1.project))),
      Enum.filter(flow.edges, &(&1.team == team and not MapSet.member?(own_flow, &1.project))),
      running_by_issue
    )
  end

  defp project_flow(slug, definition, flow, running_by_issue) do
    stage_flow(definition, Enum.filter(flow.issues, &(&1.project == slug)), Enum.filter(flow.edges, &(&1.project == slug)), running_by_issue)
  end

  defp stage_flow(definition, issues, edges, running_by_issue) do
    ids = MapSet.new(definition["stages"], & &1["id"])

    # An issue held for approval is shown in the stage it's waiting to leave,
    # with `to` naming where it goes once approved.
    members =
      issues
      |> Enum.map(fn issue ->
        if issue[:awaiting_approval] && MapSet.member?(ids, issue[:from]),
          do: issue |> Map.put(:to, issue.node) |> Map.put(:node, issue[:from]),
          else: issue
      end)
      |> Enum.filter(&MapSet.member?(ids, &1.node))
      |> Enum.group_by(& &1.node)

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
      edges
      |> Enum.filter(&(MapSet.member?(ids, &1.from) and MapSet.member?(ids, &1.to)))
      |> Enum.reduce(%{}, fn edge, acc -> Map.update(acc, "#{edge.from}>#{edge.to}", edge.count, &(&1 + edge.count)) end)

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
      backend: agent && agent.backend,
      awaiting: issue[:awaiting_approval] == true,
      from: issue[:from],
      to: issue[:to]
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
