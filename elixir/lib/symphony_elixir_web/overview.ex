defmodule SymphonyElixirWeb.Overview do
  @moduledoc """
  Work across teams by Linear state: the flow someone who sees several teams
  (or all of them) lands on with All teams and All projects picked, and what
  MCP's `symphony_status` reports.

  Teams follow different flows, so stages don't line up across them; Linear
  states do. `flow/2` draws a read-only flow whose stages are Linear states,
  ordered by Linear's state types (Triage, Backlog, Todo, In progress, Done,
  Canceled) and the teams' own state order, each holding the issues in that
  state across teams; a stage's caption names the teams whose state it is
  when not every team has it, and a type's rarer state names fold into one
  "Other" stage. `build/2` and `summary/2` group the same rows by type, then
  state name, for MCP.

  Everything comes from the factory payload's `overview` rows
  (`SymphonyElixirWeb.FactoryPresenter`), which hold only issues with the
  opt-in label and are trimmed to what the viewer may see
  (`SymphonyElixirWeb.Visibility`) before they get here: no Linear call per
  render, however many teams.
  """

  alias SymphonyElixir.Teams

  @types [
    {"triage", "Triage"},
    {"backlog", "Backlog"},
    {"unstarted", "Todo"},
    {"started", "In progress"},
    {"completed", "Done"},
    {"canceled", "Canceled"}
  ]
  @issues_per_state 25
  @issues_per_node 40
  @names_per_type 5
  @scope "overview"

  @type row :: map()

  @doc """
  The overview of `rows`. `teams:` keeps only those team keys (`[]` or nil:
  all); `issues_per_state:` caps the issues listed per state (counts stay whole).
  """
  @spec build([row()], keyword()) :: map()
  def build(rows, opts \\ []) do
    all = rows || []
    picked = opts |> Keyword.get(:teams) |> List.wrap()
    shown = if picked == [], do: all, else: Enum.filter(all, &(&1.team in picked))
    limit = Keyword.get(opts, :issues_per_state, @issues_per_state)
    names = Teams.names()

    %{
      total: length(shown),
      picked: picked,
      columns: columns(shown, limit),
      teams: teams(all, names, Keyword.get(opts, :team_keys, []))
    }
  end

  @doc "Counts only, for MCP: per state type, per state, per team."
  @spec summary([row()], keyword()) :: map()
  def summary(rows, opts \\ []) do
    overview = build(rows, Keyword.put(opts, :issues_per_state, 0))

    %{
      total: overview.total,
      by_state_type:
        for column <- overview.columns do
          %{
            state_type: column.type,
            label: column.label,
            count: column.count,
            states: Enum.map(column.states, &Map.take(&1, [:name, :count, :teams]))
          }
        end,
      by_team: Enum.map(overview.teams, &Map.take(&1, [:key, :name, :total, :counts]))
    }
  end

  @spec types() :: [{String.t(), String.t()}]
  def types, do: @types

  @doc "The flow key of the all-teams view in the factory payload."
  @spec scope() :: String.t()
  def scope, do: @scope

  @doc """
  The all-teams flow: `%{entry: entry, definition: definition, flow: flow}` in
  the shapes the factory payload uses for a team's flow, so the dashboard
  draws it like any flow (read-only).
  """
  @spec flow([row()], keyword()) :: %{entry: map(), definition: map(), flow: map()}
  def flow(rows, opts \\ []) do
    rows = rows || []
    teams = rows |> Enum.map(& &1.team) |> Kernel.++(Keyword.get(opts, :team_keys, [])) |> Enum.uniq()
    nodes = state_nodes(rows)

    stages =
      nodes
      |> Enum.with_index()
      |> Enum.map(fn {node, i} -> state_stage(node, i, nodes, length(teams)) end)

    main = Enum.reject(stages, &(&1["kind"] == "parked"))

    transitions =
      main
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> %{"from" => a["id"], "to" => b["id"], "by" => "human", "criteria" => ""} end)
      |> Kernel.++(for c <- stages -- main, last = List.last(main), last, do: %{"from" => last["id"], "to" => c["id"], "by" => "human", "criteria" => ""})

    definition = %{
      "version" => 0,
      "stages" => stages,
      "transitions" => transitions,
      "autopilot" => %{"enabled" => false, "streak" => 0},
      "team" => @scope,
      "source" => @scope,
      "inherited" => false,
      "derived" => true
    }

    flow_nodes =
      Map.new(Enum.zip(stages, nodes), fn {stage, node} ->
        issues = node.rows |> Enum.sort_by(&(-(&1.since_ms || 0))) |> Enum.take(@issues_per_node) |> Enum.map(&issue_row/1)
        {stage["id"], %{issues: issues, count: length(node.rows), running: Enum.count(node.rows, & &1.running)}}
      end)

    %{
      entry: %{key: @scope, kind: "overview", name: "All teams · Linear states", custom: true},
      definition: definition,
      flow: %{nodes: flow_nodes, edges: %{}}
    }
  end

  # Linear's usual states are always drawn, so an empty factory still reads
  # Backlog -> Todo -> In Progress -> In Review -> Done.
  @skeleton [{"backlog", "Backlog"}, {"unstarted", "Todo"}, {"started", "In Progress"}, {"started", "In Review"}, {"completed", "Done"}, {"canceled", "Canceled"}]

  # One node per state name (case-insensitive) within each type, the busiest
  # @names_per_type, then the rest folded into "Other <type>".
  defp state_nodes(rows) do
    by_name = Enum.group_by(rows, &{type_of(&1), String.downcase(&1.state || "unknown")})

    for {type, label} <- @types do
      named =
        @skeleton
        |> Enum.filter(&(elem(&1, 0) == type))
        |> Enum.map(fn {_type, name} -> {String.downcase(name), name} end)
        |> Kernel.++(for {{^type, key}, [row | _]} <- by_name, do: {key, row.state || "Unknown"})
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.map(fn {key, name} -> %{type: type, names: [name], rows: Map.get(by_name, {type, key}, []), order: order(type, name)} end)
        |> Enum.sort_by(&{-length(&1.rows), &1.order})

      {kept, rest} = Enum.split(named, @names_per_type)
      kept = Enum.sort_by(kept, &{&1.order, hd(&1.names)})
      rest = Enum.reject(rest, &(&1.rows == []))

      kept ++ other_node(type, label, rest)
    end
    |> List.flatten()
    |> Enum.reject(&(&1.rows == [] and &1.type in ["triage"]))
  end

  defp other_node(_type, _label, []), do: []

  defp other_node(type, label, rest) do
    names = Enum.flat_map(rest, & &1.names)
    [%{type: type, names: names, rows: Enum.flat_map(rest, & &1.rows), order: 10_000, other: label}]
  end

  # A state's place among its type's: Linear's usual states first, then the
  # teams' own state order where known.
  defp order(type, name) do
    positions = for team <- Teams.list(), %{name: n, type: ^type, position: p} <- team.states, String.downcase(n) == String.downcase(name), do: p
    skeleton = Enum.find_index(@skeleton, fn {_t, n} -> String.downcase(n) == String.downcase(name) end)

    cond do
      skeleton -> skeleton
      positions != [] -> 10 + Enum.sum(positions) / length(positions)
      true -> 1_000
    end
  end

  @kinds %{"triage" => "queue", "backlog" => "queue", "unstarted" => "queue", "started" => "agent", "completed" => "done", "canceled" => "parked"}

  defp state_stage(node, i, nodes, team_count) do
    main_count = Enum.count(nodes, &(&1.type != "canceled"))
    {x, y} = if node.type == "canceled", do: {78 + (main_count - 1) * 196, 300}, else: {78 + i * 196, 165}
    name = if node[:other], do: "Other #{String.downcase(node.other)}", else: hd(node.names)
    teams = node.rows |> Enum.map(& &1.team) |> Enum.uniq() |> Enum.sort()

    caption =
      cond do
        node[:other] -> Enum.join(node.names, " · ")
        teams != [] and length(teams) < team_count -> Enum.join(teams, " · ")
        true -> nil
      end

    %{
      "id" => stage_id(node),
      "name" => name,
      "kind" => @kinds[node.type],
      "linear_state" => Enum.join(node.names, " · "),
      "label" => caption && truncate(caption, 34),
      "default" => false,
      "instructions" =>
        "Issues in Linear state #{Enum.join(node.names, ", ")} (#{label_of(node.type)}) across teams: #{if teams == [], do: "none right now", else: Enum.join(teams, ", ")}. Pick a team at the top to see its own flow and act on its issues.",
      "harness" => nil,
      "effort" => nil,
      "environment" => nil,
      "max_agents" => nil,
      "paused" => false,
      "approval" => false,
      "approval_streak" => 0,
      "checks" => [],
      "skill" => nil,
      "position" => %{"x" => x, "y" => y}
    }
  end

  defp stage_id(%{other: _label, type: type}), do: "other-" <> type
  defp stage_id(%{type: type, names: [name | _]}), do: type <> "-" <> (name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-"))

  defp label_of(type), do: @types |> List.keyfind(type, 0, {type, type}) |> elem(1)

  defp truncate(text, max), do: if(String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text)

  defp issue_row(row) do
    %{
      id: row[:id],
      issue: row.issue,
      title: row.title,
      url: row.url,
      project: row.project,
      team: row.team,
      stage_name: row.stage_name,
      state: row.state,
      since_ms: row.since_ms,
      backend: row[:backend],
      awaiting: row.awaiting,
      from: nil,
      to: nil,
      knockbacks: %{}
    }
  end

  defp columns(rows, limit) do
    by_type = Enum.group_by(rows, &type_of/1)

    for {type, label} <- @types, issues = Map.get(by_type, type, []), issues != [] do
      %{type: type, label: label, count: length(issues), states: states(issues, limit)}
    end
  end

  defp states(rows, limit) do
    rows
    |> Enum.group_by(&(&1.state || "Unknown"))
    |> Enum.map(fn {name, issues} ->
      %{
        name: name,
        count: length(issues),
        teams: issues |> Enum.frequencies_by(& &1.team) |> Enum.sort_by(fn {team, n} -> {-n, team} end) |> Map.new(),
        issues: issues |> Enum.sort_by(&{not &1.awaiting, not &1.running, -(&1.since_ms || 0)}) |> Enum.take(limit)
      }
    end)
    |> Enum.sort_by(&{-&1.count, &1.name})
  end

  # Every team the viewer can see, busiest first, with counts per state type.
  defp teams(rows, names, team_keys) do
    by_team = Enum.group_by(rows, & &1.team)

    (Map.keys(by_team) ++ team_keys)
    |> Enum.uniq()
    |> Enum.map(fn key ->
      issues = Map.get(by_team, key, [])

      %{
        key: key,
        name: names[key],
        total: length(issues),
        running: Enum.count(issues, & &1.running),
        counts: Enum.frequencies_by(issues, &type_of/1)
      }
    end)
    |> Enum.sort_by(&{-&1.total, &1.key})
  end

  defp type_of(%{state_type: type}) when is_binary(type), do: if(List.keymember?(@types, type, 0), do: type, else: "started")
  defp type_of(_row), do: "started"
end
