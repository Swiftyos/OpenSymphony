defmodule SymphonyElixirWeb.InsightsLive do
  @moduledoc """
  Traces and metrics for the factory, read from the factory's own ClickHouse
  (OpenTelemetry metrics and spans) and Langfuse (traces with usage and cost)
  through `SymphonyElixir.Observability`.

  The page shows factory-wide totals and charts for a time range, the issues
  and tools that used the most, and for one picked issue its metrics, recent
  traces, and a waterfall of the trace you open. Issues the viewer can't see
  are left out.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}
  import SymphonyElixirWeb.Charts
  import SymphonyElixirWeb.Topbar

  alias SymphonyElixir.{Config, Observability}
  alias SymphonyElixirWeb.Visibility

  @ranges [{"hour", "1h"}, {"day", "24h"}, {"week", "7d"}]
  @refresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     socket
     |> assign(instance_name: Config.instance_name(), range: "day", issue: nil, trace_id: nil, trace: nil)
     |> assign(ranges: @ranges)
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = if params["range"] in Enum.map(@ranges, &elem(&1, 0)), do: params["range"], else: "day"
    issue = visible_issue(params["issue"], socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(range: range, issue: issue, trace_id: issue && params["trace"])
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

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <.topbar instance_name={@instance_name} current_user={@current_user} current="insights">
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
            <.bar_list rows={issue_rows(@overview, @range)} empty="No issue has reported telemetry in this range." />
          </section>

          <section class="panel">
            <div class="panel-head">
              <h3 class="panel-title">Busiest tools</h3>
            </div>
            <.bar_list rows={tool_rows(@overview)} empty="No tool calls in this range." />
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
                    <span class="trace-meta">{trace[:span_count] && "#{trace.span_count} spans"}</span>
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

  defp load(socket) do
    %{range: range, issue: issue, trace_id: trace_id} = socket.assigns
    range_atom = String.to_existing_atom(range)

    {overview, overview_error} = result(Observability.factory_overview(range_atom))

    {issue_metrics, issue_error, traces} =
      if issue do
        {metrics, error} = result(Observability.issue_metrics(issue, range_atom))

        traces =
          case Observability.issue_traces(issue, 20),
            do: (
              {:ok, list} -> list
              _ -> []
            )

        {metrics, error, traces}
      else
        {nil, nil, []}
      end

    trace =
      if trace_id,
        do:
          case(Observability.trace(trace_id),
            do: (
              {:ok, t} -> t
              _ -> nil
            )
          )

    assign(socket,
      overview: overview && Map.update(overview, :top_issues, [], &visible_rows(&1, socket.assigns.current_user)),
      overview_error: overview_error,
      issue_metrics: issue_metrics,
      issue_error: issue_error,
      traces: traces,
      trace: trace,
      sources: Observability.status()
    )
  end

  defp result({:ok, data}), do: {data, nil}
  defp result({:error, :not_configured}), do: {nil, "Traces and metrics aren't set up: add an `observability` section to Symphony's config."}
  defp result({:error, reason}), do: {nil, "Couldn't read telemetry: #{inspect(reason)}"}

  defp visible_issue(nil, _user), do: nil

  defp visible_issue(identifier, user) when is_binary(identifier) do
    if Visibility.filter_issue(%{}, user, identifier) == :hidden, do: nil, else: identifier
  end

  defp visible_rows(rows, user), do: Enum.reject(rows, &(Visibility.filter_issue(%{}, user, &1.identifier) == :hidden))

  defp issue_rows(overview, range) do
    overview
    |> Map.get(:top_issues, [])
    |> Enum.map(&%{label: &1.identifier, detail: &1[:title], value: &1[:tokens] || 0, href: "/insights?range=#{range}&issue=#{&1.identifier}"})
  end

  defp tool_rows(overview), do: overview |> Map.get(:top_tools, []) |> Enum.map(&%{label: &1.name, value: &1.calls})

  defp model_rows(nil), do: []
  defp model_rows(metrics), do: metrics |> Map.get(:by_model, []) |> Enum.map(&%{label: &1.model, value: &1[:tokens] || 0})

  defp path(assigns, changes) do
    params =
      %{"range" => assigns.range, "issue" => assigns.issue, "trace" => assigns.trace_id}
      |> Map.merge(Map.new(changes, fn {k, v} -> {to_string(k), v} end))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    "/insights?" <> URI.encode_query(params)
  end

  # ------------------------------------------------------------------ labels

  defp tokens_detail(totals) when is_map(totals) do
    "in #{compact(totals[:input_tokens])} · out #{compact(totals[:output_tokens])}"
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
  defp source_class(%{state: :not_configured}), do: "is-off"
  defp source_class(_status), do: "is-down"

  defp source_title(%{state: :ok}), do: "Connected"
  defp source_title(%{state: :not_configured}), do: "Not configured"
  defp source_title(%{error: error}), do: "Unreachable: #{inspect(error)}"
  defp source_title(_status), do: "Unknown"

  defp short_id(nil), do: ""
  defp short_id(id), do: String.slice(id, 0, 12)

  defp when_label(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %H:%M")
  defp when_label(at) when is_binary(at), do: at
  defp when_label(_at), do: ""
end
