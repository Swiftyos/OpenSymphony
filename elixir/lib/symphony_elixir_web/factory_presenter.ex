defmodule SymphonyElixirWeb.FactoryPresenter do
  @moduledoc """
  Shapes the usage ledger and live sessions into the compact payload behind the
  dashboard's factory diagram and cost explorer.

  The browser receives this once per orchestrator update and does all grouping,
  filtering, and hover work client-side, so interactions never wait on a server
  round-trip.
  """

  alias SymphonyElixir.Factory.{Definition, Store}
  alias SymphonyElixir.{IssueStage, Pricing, Teams, UsageLedger}

  # Fixed harness order: color follows the harness, never its rank.
  @harnesses ["codex", "claude", "opencode"]
  @issues_per_stage 40
  @overview_settled_ms 14 * 86_400_000

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
    team_names = Teams.names()
    projects = project_entries(settings)
    own_flow = MapSet.new(Store.projects())
    # The default flow is always on offer (admins edit it; every team without
    # its own follows it), ahead of the teams.
    scopes = [Store.default_team() | teams]

    definitions =
      Map.new(scopes, &{&1, Store.get(&1)})
      |> Map.merge(Map.new(projects, &{&1.key, Store.get(&1.key, List.first(&1.teams))}))

    team_flows = Map.new(scopes, &{&1, team_flow(&1, definitions[&1], ledger.flow, running_by_issue, own_flow)})
    project_flows = Map.new(projects, &{&1.key, project_flow(&1.slug, definitions[&1.key], ledger.flow, running_by_issue)})

    %{
      harnesses: @harnesses,
      # The model each harness runs (from its config), shown next to the harness.
      harness_models: Map.new(@harnesses, &{&1, UsageLedger.model_label(&1)}),
      capacity: settings.agent.max_concurrent_agents,
      controls_enabled: controls_enabled?(settings),
      priced: map_size(pricing) > 0,
      usage: Enum.map(ledger.usage, &(&1 |> price_row(pricing) |> Map.update(:url, nil, fn url -> https_url(url) end))),
      team: List.first(teams) || Store.default_team(),
      teams:
        Enum.map(scopes, &%{key: &1, kind: team_kind(&1), name: if(&1 == Store.default_team(), do: "Default flow", else: team_names[&1]), custom: Store.custom?(&1)}) ++
          Enum.map(projects, &Map.take(&1, [:key, :kind, :name, :slug, :teams, :custom])),
      definitions: definitions,
      flows: Map.merge(team_flows, project_flows),
      linear_states: linear_states(settings, definitions),
      label_prefix: IssueStage.label_prefix(settings),
      approval_label: IssueStage.approval_label(settings),
      # Server-rendered (the overview), never sent to the browser as JSON.
      overview: overview_rows(ledger.flow.issues, definitions, running_by_issue)
    }
  end

  # Teams with work, teams with their own flow, teams Symphony knows
  # (`SymphonyElixir.Teams`), and any extra (viewer's) teams.
  defp team_keys(issues, extra) do
    issues
    |> Enum.map(& &1.team)
    |> Kernel.++(Store.teams())
    |> Kernel.++(Teams.keys())
    |> Kernel.++(extra)
    |> Enum.filter(&(is_binary(&1) and &1 != Store.default_team()))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Every tracked issue (already only those with the opt-in label), by its
  # Linear state, for the overview across teams. Finished and canceled issues
  # stay for @overview_settled_ms.
  defp overview_rows(issues, definitions, running_by_issue) do
    settled_after = System.system_time(:millisecond) - @overview_settled_ms

    for issue <- issues, is_binary(issue.team) do
      overview_row(issue, definitions, running_by_issue)
    end
    |> Enum.reject(&(&1.state_type in ["completed", "canceled"] and &1.since_ms < settled_after))
  end

  defp overview_row(issue, definitions, running_by_issue) do
    scope = Store.scope_for(issue.team, issue.project)
    stage = Definition.stage(definitions[scope] || Store.get(scope, issue.team), issue.node)
    state = issue[:state] || stage_state(stage) || node_state(issue.node)
    agent = Map.get(running_by_issue, issue.issue)

    %{
      issue: issue.issue,
      id: issue[:id],
      title: issue.title,
      url: https_url(issue.url),
      team: issue.team,
      project: issue.project,
      state: state,
      state_type: issue[:state_type] || Teams.state_type(issue.team, state) || guess_state_type(state, stage),
      stage: issue.node,
      stage_name: (stage && stage["name"]) || issue.node,
      since_ms: issue.since_ms,
      running: agent != nil,
      backend: agent && agent.backend,
      awaiting: issue[:awaiting_approval] == true
    }
  end

  defp stage_state(%{"linear_state" => state}), do: state
  defp stage_state(_stage), do: nil

  defp node_state("canceled"), do: "Canceled"
  defp node_state("backlog"), do: "Backlog"
  defp node_state(_node), do: nil

  @state_types_by_name %{
    "canceled" => "canceled",
    "cancelled" => "canceled",
    "duplicate" => "canceled",
    "closed" => "canceled",
    "done" => "completed",
    "completed" => "completed",
    "merged" => "completed",
    "backlog" => "backlog",
    "triage" => "triage",
    "todo" => "unstarted",
    "to do" => "unstarted",
    "ready" => "unstarted"
  }

  # Rows saved before states were kept: the type from the stage, else the name.
  defp guess_state_type(_state, %{"kind" => "done"}), do: "completed"

  defp guess_state_type(state, stage) do
    name = if is_binary(state), do: String.downcase(String.trim(state))

    cond do
      Map.has_key?(@state_types_by_name, name) -> @state_types_by_name[name]
      match?(%{"kind" => "queue"}, stage) -> "unstarted"
      true -> "started"
    end
  end

  defp team_kind(key), do: if(key == Store.default_team(), do: "default", else: "team")

  # Configured projects, projects with work, and projects with their own flow;
  # never one removed from Symphony (its history stays, hidden).
  defp project_entries(settings) do
    seen = UsageLedger.projects()
    removed = SymphonyElixir.ProjectRoutes.removed()
    linear_names = SymphonyElixir.LabelSync.project_names()
    linear_teams = SymphonyElixir.LabelSync.project_teams()

    settings.tracker.projects
    |> List.wrap()
    |> Enum.map(& &1.slug)
    |> Kernel.++(Map.keys(seen))
    |> Kernel.++(Store.projects())
    |> Enum.filter(&(is_binary(&1) and is_binary(Store.project_scope(&1)) and not MapSet.member?(removed, &1)))
    |> Enum.uniq()
    |> Enum.map(fn slug ->
      info = Map.get(seen, slug, %{name: nil, teams: []})
      key = Store.project_scope(slug)
      name = info.name || linear_names[slug] || slug
      # Teams whose issues it holds, then the teams Linear says it belongs to.
      teams = Enum.uniq(info.teams ++ Map.get(linear_teams, slug, []))
      %{key: key, kind: "project", slug: slug, name: name, teams: teams, custom: Store.custom?(key)}
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
           issues: issues |> Enum.sort_by(& &1.since_ms, :desc) |> Enum.take(@issues_per_stage) |> Enum.map(&issue_row(&1, running_by_issue, definition)),
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

  defp issue_row(issue, running_by_issue, definition) do
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
      to: issue[:to],
      knockbacks: knockbacks(issue, definition)
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
  # How often each stage sent the issue back, e.g. %{"Test" => 2, "Review" => 1}.
  defp knockbacks(issue, definition), do: SymphonyElixir.IssueReport.rounds(issue[:moves] || [], definition).knockbacks

  defp https_url("https://" <> _rest = url), do: url
  defp https_url(_url), do: nil

  # Usage priced when it was spent is used as is. Older usage, recorded before
  # pricing, is priced at today's rates (cache reads at the cached rate).
  defp price_row(%{cost_micros: micros} = row, _pricing) when is_integer(micros) and micros > 0,
    do: Map.put(row, :cost_usd, micros / 1_000_000)

  defp price_row(row, pricing) do
    cost =
      if map_size(pricing) > 0 do
        case Pricing.cost_micros(row.backend, row.model, row, DateTime.utc_now(), pricing) do
          nil -> nil
          micros -> micros / 1_000_000
        end
      end

    Map.put(row, :cost_usd, cost)
  end
end
