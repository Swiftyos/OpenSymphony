defmodule SymphonyElixirWeb.Charts do
  @moduledoc """
  Small server-rendered SVG charts for the traces and metrics page: stacked
  bars over time (one colour per harness), a horizontal bar list, and a trace
  waterfall. No JavaScript; each bar carries a `<title>` for its tooltip.
  """

  use Phoenix.Component

  @harness_order ["codex", "claude", "opencode"]

  attr(:points, :list, required: true, doc: "[%{at: DateTime | label, values: %{series => number}}]")
  attr(:format, :any, default: nil, doc: "fn number -> string for tooltips and the axis")
  attr(:height, :integer, default: 160)
  attr(:label, :string, required: true)

  @spec stacked_bars(map()) :: Phoenix.LiveView.Rendered.t()
  def stacked_bars(assigns) do
    points = assigns.points
    series = points |> Enum.flat_map(&Map.keys(&1.values)) |> Enum.uniq() |> Enum.sort_by(&series_rank/1)
    max = points |> Enum.map(&total/1) |> Enum.max(fn -> 0 end)
    count = max(length(points), 1)
    width = 600
    slot = width / count
    bar = max(slot * 0.68, 1.5)
    height = assigns.height
    fmt = assigns.format || (&compact/1)

    bars =
      points
      |> Enum.with_index()
      |> Enum.map(fn {point, i} ->
        segments = segments(point, series, max, height)
        %{x: i * slot + (slot - bar) / 2, w: bar, segments: segments, label: point_label(point), total: total(point)}
      end)

    assigns = assign(assigns, bars: bars, series: series, max: max, width: width, fmt: fmt, first: List.first(points), last: List.last(points))

    ~H"""
    <figure class="chart">
      <svg class="chart-svg" viewBox={"0 0 #{@width} #{@height}"} preserveAspectRatio="none" role="img" aria-label={@label}>
        <line class="chart-grid" x1="0" x2={@width} y1={@height - 0.5} y2={@height - 0.5} />
        <line class="chart-grid" x1="0" x2={@width} y1="18" y2="18" />
        <g :for={bar <- @bars}>
          <rect
            :for={seg <- bar.segments}
            class={"chart-bar h-#{seg.name}"}
            x={bar.x}
            y={seg.y}
            width={bar.w}
            height={seg.h}
            rx={min(bar.w / 3, 3)}
          >
            <title>{bar.label} · {seg.name}: {@fmt.(seg.value)} (total {@fmt.(bar.total)})</title>
          </rect>
        </g>
      </svg>
      <figcaption class="chart-axis">
        <span>{@first && point_label(@first)}</span>
        <span class="chart-max">peak {@fmt.(@max)}</span>
        <span>{@last && point_label(@last)}</span>
      </figcaption>
    </figure>
    """
  end

  attr(:rows, :list, required: true, doc: "[%{label, value, detail?, href?}]")
  attr(:format, :any, default: nil)
  attr(:empty, :string, default: "Nothing yet.")

  @spec bar_list(map()) :: Phoenix.LiveView.Rendered.t()
  def bar_list(assigns) do
    max = assigns.rows |> Enum.map(&(&1.value || 0)) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, max: max, fmt: assigns.format || (&compact/1))

    ~H"""
    <p :if={@rows == []} class="empty-state">{@empty}</p>
    <ol :if={@rows != []} class="bar-list">
      <li :for={row <- @rows} class="bar-list-row">
        <span class="bar-list-label" title={row[:detail] || row.label}>
          <a :if={row[:href]} href={row.href} phx-click={row[:click]} phx-value-id={row[:id]}>{row.label}</a>
          <span :if={!row[:href]}>{row.label}</span>
        </span>
        <span class="bar-list-track">
          <span class="bar-list-fill" style={"width: #{pct(row.value, @max)}%"}></span>
        </span>
        <span class="bar-list-value numeric">{@fmt.(row.value)}</span>
      </li>
    </ol>
    """
  end

  attr(:spans, :list, required: true, doc: "[%{id, parent_id, name, start_ms, duration_ms, status?, detail?}]")

  @spec waterfall(map()) :: Phoenix.LiveView.Rendered.t()
  def waterfall(assigns) do
    spans = assigns.spans
    ends = Enum.map(spans, &((&1.start_ms || 0) + (&1.duration_ms || 0)))
    total = max(Enum.max(ends, fn -> 0 end), 1)
    assigns = assign(assigns, rows: tree_order(spans), total: total)

    ~H"""
    <div class="waterfall" role="table" aria-label="Spans">
      <div class="wf-scale" aria-hidden="true">
        <span>0</span><span>{ms(@total / 2)}</span><span>{ms(@total)}</span>
      </div>
      <div :for={{span, depth} <- @rows} class={["wf-row", span[:status] == "error" && "is-error"]} role="row">
        <span class="wf-name" style={"padding-left: #{depth * 14}px"} title={span[:detail] || span.name}>{span.name}</span>
        <span class="wf-track">
          <span
            class="wf-bar"
            style={"left: #{pct(span.start_ms || 0, @total)}%; width: max(2px, #{pct(span.duration_ms || 0, @total)}%)"}
          ></span>
        </span>
        <span class="wf-dur numeric">{ms(span.duration_ms)}</span>
      </div>
    </div>
    """
  end

  # One bar's stacked pieces, bottom up, in series order; empty ones dropped.
  defp segments(point, series, max, height) do
    series
    |> Enum.map_reduce(0.0, fn name, base ->
      value = Map.get(point.values, name, 0) || 0
      h = if max > 0, do: value / max * (height - 18), else: 0
      {%{name: name, y: height - base - h, h: h, value: value}, base + h}
    end)
    |> elem(0)
    |> Enum.filter(&(&1.h > 0))
  end

  # Parents before children, children by start time; orphans at the top level.
  defp tree_order(spans) do
    ids = MapSet.new(spans, & &1.id)
    children = Enum.group_by(spans, fn s -> if s[:parent_id] in ids, do: s.parent_id, else: :root end)
    walk(children, :root, 0)
  end

  defp walk(children, parent, depth) do
    children
    |> Map.get(parent, [])
    |> Enum.sort_by(&(&1.start_ms || 0))
    |> Enum.flat_map(fn span -> [{span, depth} | walk(children, span.id, depth + 1)] end)
  end

  # ------------------------------------------------------------------ format

  @doc false
  @spec compact(number() | nil) :: String.t()
  def compact(nil), do: "0"
  def compact(n) when n >= 1_000_000_000, do: "#{trim(n / 1_000_000_000)}B"
  def compact(n) when n >= 1_000_000, do: "#{trim(n / 1_000_000)}M"
  def compact(n) when n >= 1_000, do: "#{trim(n / 1_000)}k"
  def compact(n) when is_float(n), do: trim(n)
  def compact(n), do: to_string(n)

  @doc false
  @spec money(number() | nil) :: String.t()
  def money(nil), do: "$0"
  def money(n) when n >= 100, do: "$#{round(n)}"
  def money(n), do: "$" <> :erlang.float_to_binary(n * 1.0, decimals: 2)

  @doc false
  @spec ms(number() | nil) :: String.t()
  def ms(nil), do: "–"
  def ms(n) when n >= 3_600_000, do: "#{trim(n / 3_600_000)}h"
  def ms(n) when n >= 60_000, do: "#{trim(n / 60_000)}m"
  def ms(n) when n >= 1_000, do: "#{trim(n / 1_000)}s"
  def ms(n), do: "#{round(n)}ms"

  defp trim(f) when is_float(f), do: f |> Float.round(1) |> then(&if(&1 == trunc(&1), do: trunc(&1), else: &1)) |> to_string()

  defp pct(_value, max) when max in [0, 0.0], do: 0
  defp pct(value, max), do: Float.round((value || 0) / max * 100, 2)

  defp total(point), do: point.values |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.sum()

  defp point_label(%{at: %DateTime{} = at}), do: Calendar.strftime(at, "%d %b %H:%M")
  defp point_label(%{at: at}) when is_binary(at), do: at
  defp point_label(_point), do: ""

  defp series_rank(name), do: Enum.find_index(@harness_order, &(&1 == name)) || 99
end
