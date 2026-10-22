defmodule SymphonyElixir.UsageLedger do
  @moduledoc """
  Durable, cheap-to-read record of token usage and factory flow.

  Token usage is kept per `{project, team, issue, backend, model, stage}` so the
  dashboard can slice cost by project, team, or task and split it by harness.
  Flow tracking records each issue's current factory node (state + stage) and
  counts every observed node-to-node transition, which is what the dashboard's
  process diagram draws (for example how often `review` looped back to `rework`).

  Writes go straight to public ETS tables from the orchestrator process and reads
  are a table scan, so snapshots stay in the microsecond range. The tables are
  flushed to JSON on an interval and reloaded on start.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AgentMetrics, Config, IssueStage, Pricing}
  alias SymphonyElixir.Factory.{Definition, Store}
  alias SymphonyElixir.Linear.Issue

  @usage_table :symphony_usage_ledger
  @issues_table :symphony_flow_issues
  @edges_table :symphony_flow_edges
  @flush_interval_ms 10_000
  @format_version 1

  # ETS tuple positions for usage rows: {key, input, output, meta, cached_input, cost_micros}
  @input_pos 2
  @output_pos 3
  @cached_pos 5
  @cost_pos 6
  @max_moves 200

  @type node_name :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Adds a token delta for the issue carried by a running entry.
  """
  @spec record_tokens(map(), map()) :: :ok
  def record_tokens(running_entry, token_delta)

  def record_tokens(%{issue: %Issue{} = issue} = running_entry, %{input_tokens: input, output_tokens: output} = delta)
      when is_integer(input) and is_integer(output) and (input > 0 or output > 0) do
    backend = Map.get(running_entry, :backend) || Config.agent_backend()
    AgentMetrics.tokens(backend, delta)

    if ready?() do
      # The stage the issue is in while the tokens are spent, so cost splits by stage.
      stage = factory_node(issue)
      model = usage_model(running_entry, delta, backend)
      key = {issue.project_slug, team_key(issue.identifier), issue.identifier, backend, model, stage}
      meta = %{title: issue.title, project_name: issue.project_name, url: issue.url}
      cached = min(Map.get(delta, :cached_input_tokens) || 0, input)
      cost = usage_cost(backend, model, Map.put(delta, :cached_input_tokens, cached))

      counters = [{@input_pos, input}, {@output_pos, output}, {@cached_pos, cached}, {@cost_pos, cost}]

      :ets.update_counter(@usage_table, key, counters, {key, 0, 0, meta, 0, 0})
      :ets.update_element(@usage_table, key, {4, meta})
      mark_dirty()
    end

    :ok
  end

  def record_tokens(_running_entry, _token_delta), do: :ok

  # The model the harness reported for this usage, else the configured one.
  defp usage_model(running_entry, delta, backend), do: Map.get(delta, :model) || Map.get(running_entry, :model) || model_label(backend)

  # The harness's own cost when it reports one (Claude Code does); otherwise
  # priced now, at the rates in force now (OpenRouter prices vary by time of day).
  defp usage_cost(backend, model, delta), do: Map.get(delta, :cost_micros) || Pricing.cost_micros(backend, model, delta) || 0

  @doc """
  Records where an issue currently sits in the factory and counts the transition
  when that changed since the last observation.

  Pass `external: true` when the issue was read back from the tracker rather
  than moved by Symphony: a move it shows into a terminal node (the flow's done
  stage, or `canceled`) was made outside the factory (a person in Linear, a PR
  merge integration) and is recorded as `[from, to, at, "external"]`.
  """
  @spec observe_issue(Issue.t(), keyword()) :: :ok
  def observe_issue(issue, opts \\ [])

  def observe_issue(%Issue{identifier: identifier} = issue, opts) when is_binary(identifier) do
    with true <- ready?(),
         node when is_binary(node) <- factory_node(issue) || observe_outside_flow(issue, opts) do
      now = System.system_time(:millisecond)

      case :ets.lookup(@issues_table, identifier) do
        # Same stage: keep where it came from, and save only if the title,
        # state, label or approval flag changed.
        [{^identifier, ^node, since, old}] ->
          meta = issue_meta(issue, old, opts)
          refresh_meta(identifier, node, since, old, meta |> Map.put(:from, old[:from]) |> Map.put(:moves, old[:moves] || []))

        [{^identifier, previous, _since, old}] ->
          meta = issue_meta(issue, old, opts)
          # Counted per team and project: their flows can share stage ids.
          # Moves of issues without the opt-in label aren't counted.
          count_edge(meta.labeled, {team_key(identifier), issue.project_slug, previous, node})
          # The issue's own move history, in order, for knock-back counts and its report.
          moves = Enum.take((old[:moves] || []) ++ [move_entry(issue, previous, node, now, opts)], -@max_moves)
          :ets.insert(@issues_table, {identifier, node, now, meta |> Map.put(:from, previous) |> Map.put(:moves, moves)})
          mark_dirty()

        [] ->
          meta = issue_meta(issue, nil, opts)
          :ets.insert(@issues_table, {identifier, node, now, meta |> Map.put(:from, nil) |> Map.put(:moves, [])})
          mark_dirty()
      end
    end

    :ok
  end

  def observe_issue(_issue, _opts), do: :ok

  # A tracked issue in a state its flow has no stage for (moved there in
  # Linear) keeps its stage, but its state and labels are brought up to date.
  defp observe_outside_flow(%Issue{identifier: identifier} = issue, opts) do
    with true <- ready?(),
         [{^identifier, node, since, old}] <- :ets.lookup(@issues_table, identifier) do
      meta = issue |> issue_meta(old, opts) |> Map.put(:from, old[:from]) |> Map.put(:moves, old[:moves] || [])
      refresh_meta(identifier, node, since, old, meta)
    end

    :ok
  end

  defp count_edge(true, key), do: :ets.update_counter(@edges_table, key, {2, 1}, {key, 0})
  defp count_edge(_labeled, _key), do: :ok

  defp move_entry(issue, previous, node, now, opts) do
    if Keyword.get(opts, :external, false) and terminal_node?(issue, node) do
      Logger.info("Issue reached #{node} outside the factory: issue_identifier=#{issue.identifier} from=#{previous} state=#{issue.state}")
      [previous, node, now, "external"]
    else
      [previous, node, now]
    end
  end

  defp terminal_node?(_issue, "canceled"), do: true
  defp terminal_node?(issue, node), do: done_stage?(IssueStage.definition(issue), node)

  defp done_stage?(definition, node), do: match?(%{"kind" => "done"}, Definition.stage(definition, node))

  @doc """
  Linear ids of the issues the ledger still shows in an open stage of their
  flow: not its done stage, `canceled`, or `backlog`. The poll only reads issues
  in active states, so one that left them (to Done in Linear, say) is re-read by
  id to bring its stage up to date.
  """
  @spec unsettled_issue_ids() :: [String.t()]
  def unsettled_issue_ids do
    if ready?() do
      for {_identifier, node, _since, %{id: id} = meta} <- :ets.tab2list(@issues_table),
          is_binary(id) and not settled?(node, meta),
          do: id
    else
      []
    end
  end

  defp settled?(node, _meta) when node in ["canceled", "backlog"], do: true
  defp settled?(node, meta), do: done_stage?(Store.get(Store.scope_for(meta[:team], meta[:project])), node)

  defp refresh_meta(_identifier, _node, _since, meta, meta), do: :ok

  defp refresh_meta(identifier, node, since, _old, meta) do
    :ets.insert(@issues_table, {identifier, node, since, meta})
    mark_dirty()
  end

  @doc """
  Maps an issue to its node in its flow's diagram: the stage id from the flow,
  or `canceled` / `backlog` for states outside it.

  A Linear state of type `completed` the flow has no stage for still counts as
  the flow's done stage, and a canceled one (type `canceled`, or a canceled-like
  name) is the flow's stage in that state if it has one, else `canceled`.
  """
  @spec factory_node(Issue.t()) :: node_name() | nil
  def factory_node(%Issue{state: state_name} = issue) when is_binary(state_name) do
    normalized = state_name |> String.trim() |> String.downcase()

    cond do
      normalized in ["canceled", "cancelled", "duplicate", "closed"] or issue.state_type == "canceled" -> IssueStage.stage(issue) || "canceled"
      normalized == "backlog" -> "backlog"
      true -> IssueStage.stage(issue) || completed_stage(issue)
    end
  end

  def factory_node(_issue), do: nil

  defp completed_stage(%Issue{state_type: "completed"} = issue) do
    Enum.find_value(IssueStage.definition(issue)["stages"], &(&1["kind"] == "done" && &1["id"]))
  end

  defp completed_stage(_issue), do: nil

  @doc """
  Projects seen in usage or flow, by slug, with their display name and the teams
  whose issues they hold. Used to decide who may edit a project's flow.
  """
  @spec projects() :: %{String.t() => %{name: String.t() | nil, teams: [String.t()]}}
  def projects do
    if ready?() do
      flow_rows =
        for {_issue, _node, _since, meta} = row <- :ets.tab2list(@issues_table), meta[:labeled] != false do
          project_row(row)
        end

      (Enum.map(:ets.tab2list(@usage_table), &project_row/1) ++ flow_rows)
      |> Enum.filter(fn {project, _team, _issue, _name} -> is_binary(project) end)
      |> Enum.group_by(&elem(&1, 0))
      |> Map.new(fn {project, rows} -> {project, %{name: Enum.find_value(rows, &elem(&1, 3)), teams: teams_by_issue_count(rows)}} end)
    else
      %{}
    end
  end

  @doc """
  Whether the ledger tracks the issue and it lacks the opt-in label
  (`tracker.require_label`), so it must not be shown.
  """
  @spec hidden?(String.t()) :: boolean()
  def hidden?(identifier) when is_binary(identifier) do
    ready?() and match?([{_identifier, _node, _since, %{labeled: false}}], :ets.lookup(@issues_table, identifier))
  end

  def hidden?(_identifier), do: false

  @doc """
  The stage an issue was in before its current one, or nil.
  """
  @spec previous_node(String.t()) :: node_name() | nil
  def previous_node(identifier) do
    with true <- ready?(),
         [{^identifier, _node, _since, meta}] <- :ets.lookup(@issues_table, identifier) do
      meta[:from]
    else
      _ -> nil
    end
  end

  @doc """
  One issue's record: its usage rows (per stage, harness, and model) and its
  move history (`[from, to, at_ms]`, oldest first).
  """
  @spec issue_history(String.t()) :: %{usage: [map()], moves: [list()]}
  def issue_history(identifier) do
    if ready?() do
      rows = :ets.tab2list(@usage_table)
      usage = for {{_p, _t, ^identifier, _b, _m, _s}, _i, _o, _meta, _c, _cost} = row <- rows, do: usage_row(row)

      moves =
        case :ets.lookup(@issues_table, identifier) do
          [{^identifier, _node, _since, %{labeled: false}}] -> []
          [{^identifier, _node, _since, meta}] -> meta[:moves] || []
          [] -> []
        end

      %{usage: usage, moves: moves}
    else
      %{usage: [], moves: []}
    end
  end

  @doc """
  Usage and flow, for showing. Issues without `tracker.require_label` (the
  opt-in label) are left out: Symphony never shows them (it still tracks them,
  so adding the label shows them again with their history).
  """
  @spec snapshot() :: %{usage: [map()], flow: %{edges: [map()], issues: [map()]}}
  def snapshot do
    snapshot = all()
    put_in(snapshot, [:flow, :issues], Enum.filter(snapshot.flow.issues, & &1.labeled))
  end

  # Everything, opted in or not: what is saved.
  defp all do
    if ready?() do
      %{
        usage: Enum.map(:ets.tab2list(@usage_table), &usage_row/1),
        flow: %{
          edges: Enum.map(:ets.tab2list(@edges_table), &edge_row/1),
          issues: Enum.map(:ets.tab2list(@issues_table), &flow_issue_row/1)
        }
      }
    else
      %{usage: [], flow: %{edges: [], issues: []}}
    end
  end

  @doc """
  Best-effort model label used to price usage for a backend.
  """
  @spec model_label(String.t() | nil) :: String.t()
  def model_label(backend) do
    settings = Config.settings!()

    model =
      case backend do
        "codex" -> settings.codex.model || codex_model(settings.codex.command)
        "claude" -> settings.claude.model
        "opencode" -> settings.opencode.model
        _ -> nil
      end

    if is_binary(model) and model != "", do: model, else: "default"
  rescue
    _error -> "default"
  end

  @doc false
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    if ready?() do
      Enum.each([@usage_table, @issues_table, @edges_table], &:ets.delete_all_objects/1)
    end

    :ok
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())

    for table <- [@usage_table, @issues_table, @edges_table] do
      :ets.new(table, [:named_table, :public, :set, write_concurrency: true, read_concurrency: true])
    end

    :persistent_term.put({__MODULE__, :dirty}, :atomics.new(1, []))
    load(path)
    schedule_flush()

    {:ok, %{path: path}}
  end

  @impl true
  def handle_info(:flush, state) do
    persist_if_dirty(state.path)
    schedule_flush()
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    persist_if_dirty(state.path)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    persist_if_dirty(state.path)
  end

  defp ready?, do: :ets.whereis(@usage_table) != :undefined

  defp mark_dirty do
    case :persistent_term.get({__MODULE__, :dirty}, nil) do
      nil -> :ok
      ref -> :atomics.put(ref, 1, 1)
    end
  end

  defp take_dirty do
    case :persistent_term.get({__MODULE__, :dirty}, nil) do
      nil -> false
      ref -> :atomics.exchange(ref, 1, 0) == 1
    end
  end

  defp default_path do
    case Application.get_env(:symphony_elixir, :usage_ledger_path, :default) do
      :default -> Path.expand("~/.symphony/usage.json")
      path -> path
    end
  end

  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval_ms)

  defp persist_if_dirty(nil), do: :ok

  defp persist_if_dirty(path) do
    if take_dirty() do
      snapshot = all()
      body = Jason.encode!(%{version: @format_version, usage: snapshot.usage, flow: snapshot.flow})

      case SymphonyElixir.StateStore.write(path, body) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Usage ledger flush failed path=#{path} reason=#{inspect(reason)}")
      end
    end

    :ok
  end

  defp load(nil), do: :ok

  defp load(path) do
    with {:ok, body} <- SymphonyElixir.StateStore.read(path),
         {:ok, %{"usage" => usage, "flow" => flow}} <- Jason.decode(body) do
      Enum.each(usage, &load_usage_row/1)
      Enum.each(Map.get(flow, "edges", []), &load_edge/1)
      # Saved before the opt-in flag was kept: an issue an agent worked on was
      # opted in; any other is hidden until the next poll reads its labels.
      worked = MapSet.new(usage, & &1["issue"])
      Enum.each(Map.get(flow, "issues", []), &load_flow_issue(&1, worked))
    else
      {:error, :enoent} -> :ok
      other -> Logger.warning("Usage ledger load skipped path=#{path} reason=#{inspect(other, limit: 5)}")
    end

    :ok
  end

  defp load_usage_row(row) do
    key = {row["project"], row["team"], row["issue"], row["backend"], row["model"], row["stage"]}
    meta = %{title: row["title"], project_name: row["project_name"], url: row["url"]}
    :ets.insert(@usage_table, {key, row["input_tokens"] || 0, row["output_tokens"] || 0, meta, row["cached_input_tokens"] || 0, row["cost_micros"] || 0})
  end

  defp edge_row({{team, project, from, to}, count}), do: %{team: team, project: project, from: from, to: to, count: count}

  # Older ledgers have no team or project on edges; keep them under nil.
  defp load_edge(%{"from" => from, "to" => to, "count" => count} = row),
    do: :ets.insert(@edges_table, {{row["team"], row["project"], from, to}, count})

  defp load_flow_issue(row, worked) do
    meta = %{
      id: row["id"],
      title: row["title"],
      project: row["project"],
      team: row["team"],
      url: row["url"],
      awaiting_approval: row["awaiting_approval"] == true,
      state: row["state"],
      state_type: row["state_type"],
      labeled: if(is_boolean(row["labeled"]), do: row["labeled"], else: MapSet.member?(worked, row["issue"])),
      from: row["from"],
      moves: for([from, to, at | by] <- row["moves"] || [], do: [from, to, at | Enum.take(by, 1)])
    }

    :ets.insert(@issues_table, {row["issue"], row["node"], row["since_ms"], meta})
  end

  defp usage_row({{project, team, issue, backend, model, stage}, input, output, meta, cached, cost_micros}) do
    %{
      stage: stage,
      project: project,
      project_name: meta[:project_name],
      team: team,
      issue: issue,
      title: meta[:title],
      url: meta[:url],
      backend: backend,
      model: model,
      input_tokens: input,
      output_tokens: output,
      cached_input_tokens: cached,
      # Priced when spent; 0 when no price was configured at the time.
      cost_micros: cost_micros
    }
  end

  defp flow_issue_row({issue, node, since_ms, meta}) do
    %{
      issue: issue,
      id: meta[:id],
      node: node,
      since_ms: since_ms,
      title: meta[:title],
      project: meta[:project],
      team: meta[:team],
      url: meta[:url],
      awaiting_approval: meta[:awaiting_approval] == true,
      state: meta[:state],
      state_type: meta[:state_type],
      labeled: meta[:labeled] != false,
      from: meta[:from],
      moves: meta[:moves] || []
    }
  end

  defp project_row({{project, team, issue, _backend, _model, _stage}, _in, _out, meta, _cached, _cost}), do: {project, team, issue, meta[:project_name]}
  defp project_row({issue, _node, _since, meta}), do: {meta[:project], meta[:team], issue, nil}

  # Teams with the most issues in the project first.
  defp teams_by_issue_count(rows) do
    rows
    |> Enum.filter(fn {_project, team, _issue, _name} -> is_binary(team) end)
    |> Enum.uniq_by(fn {_project, team, issue, _name} -> {team, issue} end)
    |> Enum.frequencies_by(&elem(&1, 1))
    |> Enum.sort_by(fn {team, n} -> {-n, team} end)
    |> Enum.map(&elem(&1, 0))
  end

  # An issue read back from Linear (`external: true`) carries its real labels
  # and state type. A move Symphony made passes the labels it set and the
  # target state's name only, so the opt-in flag and the state type are kept
  # from the last read (a state's type is looked up in the team's states when
  # the name changed).
  defp issue_meta(%Issue{} = issue, old, opts) do
    team = team_key(issue.identifier)
    external? = Keyword.get(opts, :external, false)

    %{
      id: issue.id,
      title: issue.title,
      project: issue.project_slug,
      team: team,
      url: issue.url,
      awaiting_approval: IssueStage.awaiting_approval?(issue),
      state: issue.state,
      state_type: state_type(issue, team, old, external?),
      labeled: labeled?(issue, old, external?)
    }
  end

  defp state_type(%Issue{state_type: type}, _team, _old, true) when is_binary(type), do: type
  defp state_type(%Issue{state: state}, _team, %{state: state, state_type: type}, _external?) when is_binary(type), do: type
  defp state_type(%Issue{state: state}, team, _old, _external?), do: SymphonyElixir.Teams.state_type(team, state)

  # Issues Symphony moved were opted in when it picked them up.
  defp labeled?(issue, _old, true), do: IssueStage.opted_in?(issue, Config.settings!())
  defp labeled?(_issue, %{labeled: labeled}, false) when is_boolean(labeled), do: labeled
  defp labeled?(_issue, _old, false), do: true

  defp team_key(identifier) when is_binary(identifier) do
    case String.split(identifier, "-", parts: 2) do
      [team, _number] when team != "" -> team
      _ -> nil
    end
  end

  defp team_key(_identifier), do: nil

  defp codex_model(command) do
    with true <- is_binary(command),
         [model] <- Regex.run(~r/(?:--model|-m)[=\s]+["']?([^\s"']+)/, command, capture: :all_but_first) do
      model
    else
      _ -> nil
    end
  end
end
