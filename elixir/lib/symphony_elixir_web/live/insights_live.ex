defmodule SymphonyElixirWeb.InsightsLive do
  @moduledoc """
  Traces and metrics for the factory, read from the factory's own ClickHouse
  (OpenTelemetry metrics and spans) and Langfuse (traces with usage and cost)
  through `SymphonyElixir.Observability`.

  The page shows factory-wide totals and charts for a time range, the issues
  and tools that used the most, cost by model, and for one picked issue its
  metrics, recent traces, and a waterfall of the trace you open. Issues the
  viewer can't see are left out, and someone who doesn't see every team
  (`SymphonyElixir.Policy`) gets totals for their teams only.

  Cost by stage comes from Symphony's usage ledger instead: telemetry doesn't
  carry the stage, and the ledger keeps totals since it started (no time
  range). The top bar's team and project pickers narrow both.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}
  import SymphonyElixirWeb.Charts
  import SymphonyElixirWeb.Topbar

  alias SymphonyElixir.{Config, Observability, Policy, UsageLedger}
  alias SymphonyElixirWeb.{FactoryPresenter, ScopePicker, Visibility}

  @ranges [{"hour", "1h"}, {"day", "24h"}, {"week", "7d"}]
  @refresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     socket
     |> assign(instance_name: Config.instance_name(), range: "day", issue: nil, trace_id: nil)
     |> assign(ranges: @ranges)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = if params["range"] in Enum.map(@ranges, &elem(&1, 0)), do: params["range"], else: "day"
    issue = visible_issue(params["issue"], socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(range: range, issue: issue, trace_id: issue && params["trace"])
     |> assign_scope(params)
     |> load()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("pick_range", %{"range" => range}, socket), do: {:noreply, push_patch(socket, to: path(socket.assigns, range: range))}
  def handle_event("open_trace", %{"id" => id}, socket), do: {:noreply, push_patch(socket, to: path(socket.assigns, trace: id))}
  def handle_event("close_issue", _params, socket), do: {:noreply, push_patch(socket, to: path(socket.assigns, issue: nil, trace: nil))}

  def handle_event("pick_team", %{"team" => _team} = params, socket) do
    picked = Map.new(ScopePicker.pick(params, socket.assigns.team), fn {k, v} -> {String.to_existing_atom(k), v} end)
    {:noreply, push_patch(socket, to: path(socket.assigns, team: picked[:team], project: picked[:project]))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <.topbar
        instance_name={@instance_name}
        current_user={@current_user}
        current="insights"
        teams={@team_choices}
        team={@team}
        projects={@project_choices}
        project={@project}
      >
        <span class={["source-chip", source_class(@sources.clickhouse)]} title={source_title(@sources.clickhouse)}>ClickHouse</span>
        <span class={["source-chip", source_class(@sources.langfuse)]} title={source_title(@sources.langfuse)}>Langfuse</span>
      </.topbar>

      <div class="insights">
        <header class="insights-head">
          <div>
            <h2 class="insights-title">Traces &amp; metrics</h2>
            <p class="insights-sub">What the factory's agents spent and did, from OpenTelemetry in ClickHouse and traces in Langfuse.</p>
          </div>
          <div class="fx-seg range-picker" role="group" aria-label="Time range">
            <button
              :for={{key, label} <- @ranges}
              type="button"
              class={["fx-seg-btn", key == @range && "is-active"]}
              phx-click="pick_range"
              phx-value-range={key}
            >
              {label}
            </button>
          </div>
        </header>

        <p :if={@overview_error} class="insights-notice">{@overview_error}</p>
        <p :if={@loading and is_nil(@overview) and is_nil(@overview_error)} class="insights-notice">
          Reading ClickHouse and Langfuse…
        </p>

        <div :if={@overview} class="fx-stats kpi-row">
          <.kpi label="Tokens" value={compact(get_in(@overview, [:totals, :tokens]))} detail={tokens_detail(@overview.totals)} />
          <.kpi label="Cost" value={money(get_in(@overview, [:totals, :cost_usd]))} detail="Claude reported, Codex priced" />
          <.kpi label="Turns" value={compact(get_in(@overview, [:totals, :turns]))} detail="agent turns finished" />
          <.kpi label="Tool calls" value={compact(get_in(@overview, [:totals, :tool_calls]))} detail={errors_detail(@overview.totals)} />
          <.kpi label="API p95" value={ms(get_in(@overview, [:totals, :api_p95_ms]))} detail={"p50 " <> ms(get_in(@overview, [:totals, :api_p50_ms]))} />
        </div>

        <div :if={@overview} class="insights-grid">
          <section class="panel is-wide">
            <div class="panel-head">
              <h3 class="panel-title">Tokens over time</h3>
              <.legend series={series_names(@overview.series[:tokens])} />
            </div>
            <.stacked_bars points={@overview.series[:tokens] || []} label="Tokens by harness over time" />
          </section>

          <section class="panel">
            <div class="panel-head">
              <h3 class="panel-title">Cost over time</h3>
              <.legend series={series_names(@overview.series[:cost])} />
            </div>
            <.stacked_bars points={@overview.series[:cost] || []} format={&money/1} label="Cost by harness over time" />
          </section>

          <section class="panel">
            <div class="panel-head">
              <h3 class="panel-title">Tool calls over time</h3>
              <.legend series={series_names(@overview.series[:tool_calls])} />
            </div>
            <.stacked_bars points={@overview.series[:tool_calls] || []} label="Tool calls by harness over time" />
          </section>

          <section class="panel">
            <div class="panel-head">
              <h3 class="panel-title">Issues by tokens</h3>
              <p class="panel-hint">Pick one for its traces.</p>
            </div>
            <.bar_list rows={issue_rows(@overview, @range, @team, @project)} empty="No issue has reported telemetry in this range." />
          </section>

          <section class="panel">
            <div class="panel-head">
              <h3 class="panel-title">Busiest tools</h3>
            </div>
            <.bar_list rows={tool_rows(@overview)} empty="No tool calls in this range." />
          </section>

          <section id="cost-by-model" class="panel">
            <div class="panel-head">
              <h3 class="panel-title">Cost by model</h3>
              <p class="panel-hint">This range</p>
            </div>
            <.bar_list rows={model_cost_rows(@overview)} format={&money/1} empty="No model reported cost in this range." />
          </section>
        </div>

        <div class="insights-grid">
          <section id="cost-by-stage" class="panel">
            <div class="panel-head">
              <h3 class="panel-title">Cost by stage</h3>
              <p class="panel-hint">All time, from Symphony's usage ledger</p>
            </div>
            <.bar_list rows={@stage_costs} format={&money/1} empty="No usage recorded for these stages yet." />
          </section>
        </div>

        <section :if={@issue} id="issue-insights" class="panel">
          <div class="panel-head">
            <h3 class="panel-title">{@issue}</h3>
            <button type="button" class="fx-link-btn" phx-click="close_issue">Close</button>
          </div>

          <p :if={@issue_error} class="insights-notice">{@issue_error}</p>

          <div :if={@issue_metrics} class="fx-stats kpi-row">
            <.kpi label="Tokens" value={compact(get_in(@issue_metrics, [:totals, :tokens]))} detail={tokens_detail(@issue_metrics.totals)} />
            <.kpi label="Cost" value={money(get_in(@issue_metrics, [:totals, :cost_usd]))} detail="this range" />
            <.kpi label="Turns" value={compact(get_in(@issue_metrics, [:totals, :turns]))} detail="agent turns" />
            <.kpi label="Tool calls" value={compact(get_in(@issue_metrics, [:totals, :tool_calls]))} detail={errors_detail(@issue_metrics.totals)} />
          </div>

          <div class="insights-grid" style="margin-top: 14px">
            <div>
              <h4 class="panel-title">Recent traces</h4>
              <p :if={@traces == []} class="empty-state">No traces for this issue yet.</p>
              <ul class="trace-list">
                <li :for={trace <- @traces}>
                  <button
                    type="button"
                    class={["trace-item", trace.id == @trace_id && "is-open", trace[:error] && "is-error"]}
                    phx-click="open_trace"
                    phx-value-id={trace.id}
                  >
                    <span class="trace-name">{trace[:name] || trace.id}</span>
                    <span class="trace-meta">{trace[:span_count] && "#{compact(trace.span_count)} spans"}</span>
                    <span class="trace-meta">{ms(trace[:duration_ms])} · {when_label(trace[:started_at])}</span>
                  </button>
                </li>
              </ul>
            </div>
            <div>
              <h4 class="panel-title">By model</h4>
              <.bar_list rows={model_rows(@issue_metrics)} empty="No model usage reported." />
            </div>
          </div>

          <div :if={@trace} class="trace-detail">
            <div class="panel-head" style="margin-top: 16px">
              <h4 class="panel-title">Trace {short_id(@trace_id)}</h4>
              <a :if={@trace[:url]} class="fx-link-btn" href={@trace.url} target="_blank" rel="noopener">Open in Langfuse ↗</a>
            </div>
            <.waterfall spans={@trace[:spans] || []} />
          </div>
        </section>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:detail, :string, default: nil)

  defp kpi(assigns) do
    ~H"""
    <div class="fx-stat">
      <span class="fx-stat-label">{@label}</span>
      <strong class="fx-stat-value" id={"kpi-#{@label}-#{@value}"} phx-hook="DotMatrix" data-value={@value}>{@value}</strong>
      <span :if={@detail} class="fx-stat-detail">{@detail}</span>
    </div>
    """
  end

  attr(:series, :list, default: [])

  defp legend(assigns) do
    ~H"""
    <div class="chart-legend">
      <span :for={name <- @series}><i class={"h-#{name}"}></i>{harness_label(name)}</span>
    </div>
    """
  end

  # ------------------------------------------------------------------ data

  # Reads run in a task (a cold read takes a few seconds); the page shows what
  # it last had until the new data arrives.
  # The pickers' choices and the picked team or project, from the factory as
  # the viewer may see it; with it the ledger's cost by stage and, for a
  # project, the issues that narrow the telemetry reads.
  defp assign_scope(socket, params) do
    user = socket.assigns.current_user
    teams = if user, do: Enum.map(user.teams, & &1.key), else: []
    factory = FactoryPresenter.payload([], Config.settings!(), teams: teams)
    visible = Visibility.filter_payload(%{running: [], retrying: [], factory: factory}, user)
    %{team: team, project: project, teams: choices, projects: projects} = ScopePicker.resolve(params, visible, user)

    scoped =
      if project,
        do: Visibility.scope_to_project(visible, project),
        else: Visibility.scope_to_team(visible, team)

    assign(socket,
      team: team,
      project: project,
      team_choices: choices,
      project_choices: projects,
      project_issues: project && project |> project_issues() |> Enum.filter(&Policy.issue_visible?(user, &1, project)),
      stage_costs: stage_cost_rows(scoped.factory)
    )
  end

  # Every issue the ledger has seen in the project.
  defp project_issues(slug) do
    ledger = UsageLedger.snapshot()

    (for(%{project: ^slug, issue: issue} <- ledger.flow.issues, do: issue) ++ for(%{project: ^slug, issue: issue} <- ledger.usage, do: issue))
    |> Enum.uniq()
  end

  # Priced usage summed per stage, named from the flows on the page.
  defp stage_cost_rows(%{usage: usage, definitions: definitions}) do
    names = for {_scope, d} <- definitions, stage <- d["stages"], into: %{}, do: {stage["id"], stage["name"]}

    usage
    |> Enum.group_by(& &1[:stage])
    |> Enum.map(fn {stage, rows} ->
      %{
        label: if(stage, do: names[stage] || stage, else: "Before stages were tracked"),
        detail: "#{compact(Enum.sum(Enum.map(rows, &(&1.input_tokens + &1.output_tokens))))} tokens",
        value: rows |> Enum.map(&(&1[:cost_usd] || 0)) |> Enum.sum()
      }
    end)
    |> Enum.reject(&(&1.value == 0))
    |> Enum.sort_by(&(-&1.value))
  end

  defp stage_cost_rows(_factory), do: []

  defp load(socket) do
    %{range: range, issue: issue, trace_id: trace_id, current_user: user} = socket.assigns
    range_atom = String.to_existing_atom(range)
    scope = [team: if(is_nil(socket.assigns.project), do: socket.assigns.team), issues: socket.assigns.project_issues, teams: overview_teams(user)]

    socket
    |> assign_new(:overview, fn -> nil end)
    |> assign_new(:overview_error, fn -> nil end)
    |> assign_new(:issue_metrics, fn -> nil end)
    |> assign_new(:issue_error, fn -> nil end)
    |> assign_new(:traces, fn -> [] end)
    |> assign_new(:trace, fn -> nil end)
    |> assign_new(:sources, fn -> %{clickhouse: %{state: :loading}, langfuse: %{state: :loading}} end)
    |> assign(:loading, true)
    |> start_async(:load, fn -> fetch(range_atom, issue, trace_id, user, scope) end)
  end

  @impl true
  def handle_async(:load, {:ok, data}, socket), do: {:noreply, socket |> assign(data) |> assign(:loading, false)}

  def handle_async(:load, {:exit, reason}, socket) do
    {:noreply, assign(socket, loading: false, overview_error: "Couldn't read telemetry: #{inspect(reason)}")}
  end

  defp fetch(range, issue, trace_id, user, scope) do
    {overview, overview_error} = result(Observability.factory_overview(range, Enum.reject(scope, &is_nil(elem(&1, 1)))))

    {issue_metrics, issue_error, traces} =
      if issue do
        {metrics, error} = result(Observability.issue_metrics(issue, range))
        {metrics, error, ok_or(Observability.issue_traces(issue, 20), [])}
      else
        {nil, nil, []}
      end

    %{
      overview: overview && Map.update(overview, :top_issues, [], &visible_rows(&1, user)),
      overview_error: overview_error,
      issue_metrics: issue_metrics,
      issue_error: issue_error,
      traces: traces,
      trace: trace_id && trace_visible?(trace_id, traces, user) && ok_or(Observability.trace(trace_id), nil),
      sources: Observability.status()
    }
  end

  # Without every team, totals count the viewer's teams only.
  defp overview_teams(user) do
    case Policy.visible_teams(user) do
      :all -> nil
      teams -> teams
    end
  end

  # A trace id from the URL must be one of the open issue's traces, unless the
  # viewer sees everything.
  defp trace_visible?(trace_id, traces, user), do: Policy.sees_all?(user) or Enum.any?(traces, &(&1[:id] == trace_id))

  defp ok_or({:ok, value}, _default), do: value
  defp ok_or(_result, default), do: default

  defp result({:ok, data}), do: {data, nil}
  defp result({:error, :not_configured}), do: {nil, "Traces and metrics aren't set up: add an `observability` section to Symphony's config."}
  defp result({:error, reason}), do: {nil, "Couldn't read telemetry: #{inspect(reason)}"}

  defp visible_issue(nil, _user), do: nil

  defp visible_issue(identifier, user) when is_binary(identifier) do
    if Visibility.filter_issue(%{}, user, identifier) == :hidden, do: nil, else: identifier
  end

  defp visible_rows(rows, user), do: Enum.reject(rows, &(Visibility.filter_issue(%{}, user, &1.identifier) == :hidden))

  defp issue_rows(overview, range, team, project) do
    scope = %{range: range, issue: nil, trace_id: nil, team: team, project: project}

    overview
    |> Map.get(:top_issues, [])
    |> Enum.sort_by(&(-(&1[:tokens] || 0)))
    |> Enum.map(&%{label: &1.identifier, detail: &1[:title], value: &1[:tokens] || 0, href: path(scope, issue: &1.identifier)})
  end

  defp model_cost_rows(overview) do
    overview
    |> Map.get(:by_model, [])
    |> Enum.filter(&((&1[:cost_usd] || 0) > 0))
    |> Enum.map(&%{label: &1.model, detail: "#{harness_label(&1.backend)} · #{compact(&1[:tokens])} tokens", value: &1.cost_usd})
  end

  defp tool_rows(overview), do: overview |> Map.get(:top_tools, []) |> Enum.map(&%{label: &1.name, value: &1.calls})

  defp model_rows(nil), do: []
  defp model_rows(metrics), do: metrics |> Map.get(:by_model, []) |> Enum.map(&%{label: &1.model, value: &1[:tokens] || 0})

  defp path(assigns, changes) do
    params =
      %{"range" => assigns.range, "issue" => assigns.issue, "trace" => assigns.trace_id, "team" => assigns.team, "project" => assigns.project}
      |> Map.merge(Map.new(changes, fn {k, v} -> {to_string(k), v} end))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    "/insights?" <> URI.encode_query(params)
  end

  # ------------------------------------------------------------------ labels

  defp tokens_detail(totals) when is_map(totals) do
    cached = (totals[:cache_read_tokens] || 0) + (totals[:cache_creation_tokens] || 0)
    cache = if cached > 0, do: " · cached #{compact(cached)}", else: ""
    "in #{compact(totals[:input_tokens])}#{cache} · out #{compact(totals[:output_tokens])}"
  end

  defp tokens_detail(_totals), do: nil

  defp errors_detail(%{tool_errors: n}) when is_integer(n) and n > 0, do: "#{n} failed"
  defp errors_detail(_totals), do: "tools the agents ran"

  defp series_names(nil), do: []
  defp series_names(points), do: points |> Enum.flat_map(&Map.keys(&1.values)) |> Enum.uniq() |> Enum.sort()

  defp harness_label("codex"), do: "Codex"
  defp harness_label("claude"), do: "Claude Code"
  defp harness_label("opencode"), do: "OpenCode"
  defp harness_label(name), do: name

  defp source_class(%{state: :ok}), do: nil
  defp source_class(%{state: state}) when state in [:not_configured, :loading], do: "is-off"
  defp source_class(_status), do: "is-down"

  defp source_title(%{state: :ok}), do: "Connected"
  defp source_title(%{state: :not_configured}), do: "Not configured"
  defp source_title(%{state: :loading}), do: "Checking…"
  defp source_title(%{error: error}), do: "Unreachable: #{inspect(error)}"
  defp source_title(_status), do: "Unknown"

  defp short_id(nil), do: ""
  defp short_id(id), do: String.slice(id, 0, 12)

  defp when_label(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %H:%M")
  defp when_label(at) when is_binary(at), do: at
  defp when_label(_at), do: ""
end
