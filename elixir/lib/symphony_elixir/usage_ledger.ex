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

  alias SymphonyElixir.{Config, IssueStage, Pricing}
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
    if ready?() do
      backend = Map.get(running_entry, :backend) || Config.agent_backend()
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
  """
  @spec observe_issue(Issue.t()) :: :ok
  def observe_issue(%Issue{identifier: identifier} = issue) when is_binary(identifier) do
    with true <- ready?(),
         node when is_binary(node) <- factory_node(issue) do
      now = System.system_time(:millisecond)

      meta = issue_meta(issue)

      case :ets.lookup(@issues_table, identifier) do
        # Same stage: keep where it came from, and save only if the title or
        # approval flag changed.
        [{^identifier, ^node, since, old}] ->
          refresh_meta(identifier, node, since, old, meta |> Map.put(:from, old[:from]) |> Map.put(:moves, old[:moves] || []))

        [{^identifier, previous, _since, old}] ->
          # Counted per team and project: their flows can share stage ids.
          key = {team_key(identifier), issue.project_slug, previous, node}
          :ets.update_counter(@edges_table, key, {2, 1}, {key, 0})
          # The issue's own move history, in order, for knock-back counts and its report.
          moves = Enum.take((old[:moves] || []) ++ [[previous, node, now]], -@max_moves)
          :ets.insert(@issues_table, {identifier, node, now, meta |> Map.put(:from, previous) |> Map.put(:moves, moves)})
          mark_dirty()

        [] ->
          :ets.insert(@issues_table, {identifier, node, now, meta |> Map.put(:from, nil) |> Map.put(:moves, [])})
          mark_dirty()
      end
    end

    :ok
  end

  def observe_issue(_issue), do: :ok

  defp refresh_meta(_identifier, _node, _since, meta, meta), do: :ok

  defp refresh_meta(identifier, node, since, _old, meta) do
    :ets.insert(@issues_table, {identifier, node, since, meta})
    mark_dirty()
  end

  @doc """
  Maps an issue to its node in its team's factory diagram: the stage id from
  the team's definition, or `canceled` / `backlog` for states outside the flow.
  """
  @spec factory_node(Issue.t()) :: node_name() | nil
  def factory_node(%Issue{state: state_name} = issue) when is_binary(state_name) do
    normalized = state_name |> String.trim() |> String.downcase()

    cond do
      normalized in ["canceled", "cancelled", "duplicate", "closed"] -> "canceled"
      normalized == "backlog" -> "backlog"
      true -> IssueStage.stage(issue)
    end
  end

  def factory_node(_issue), do: nil

  @doc """
  Projects seen in usage or flow, by slug, with their display name and the teams
  whose issues they hold. Used to decide who may edit a project's flow.
  """
  @spec projects() :: %{String.t() => %{name: String.t() | nil, teams: [String.t()]}}
  def projects do
    if ready?() do
      (Enum.map(:ets.tab2list(@usage_table), &project_row/1) ++ Enum.map(:ets.tab2list(@issues_table), &project_row/1))
      |> Enum.filter(fn {project, _team, _issue, _name} -> is_binary(project) end)
      |> Enum.group_by(&elem(&1, 0))
      |> Map.new(fn {project, rows} -> {project, %{name: Enum.find_value(rows, &elem(&1, 3)), teams: teams_by_issue_count(rows)}} end)
    else
      %{}
    end
  end

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
          [{^identifier, _node, _since, meta}] -> meta[:moves] || []
          [] -> []
        end

      %{usage: usage, moves: moves}
    else
      %{usage: [], moves: []}
    end
  end

  @spec snapshot() :: %{usage: [map()], flow: %{edges: [map()], issues: [map()]}}
  def snapshot do
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
      snapshot = snapshot()
      body = Jason.encode!(%{version: @format_version, usage: snapshot.usage, flow: snapshot.flow})

      case SymphonyElixir.PrivateFile.write(path, body) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Usage ledger flush failed path=#{path} reason=#{inspect(reason)}")
      end
    end

    :ok
  end

  defp load(nil), do: :ok

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"usage" => usage, "flow" => flow}} <- Jason.decode(body) do
      Enum.each(usage, &load_usage_row/1)
      Enum.each(Map.get(flow, "edges", []), &load_edge/1)
      Enum.each(Map.get(flow, "issues", []), &load_flow_issue/1)
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

  defp load_flow_issue(row) do
    meta = %{
      id: row["id"],
      title: row["title"],
      project: row["project"],
      team: row["team"],
      url: row["url"],
      awaiting_approval: row["awaiting_approval"] == true,
      from: row["from"],
      moves: for([from, to, at] <- row["moves"] || [], do: [from, to, at])
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

  defp issue_meta(%Issue{} = issue) do
    %{
      id: issue.id,
      title: issue.title,
      project: issue.project_slug,
      team: team_key(issue.identifier),
      url: issue.url,
      awaiting_approval: IssueStage.awaiting_approval?(issue)
    }
  end

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
