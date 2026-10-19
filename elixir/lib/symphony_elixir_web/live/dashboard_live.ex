defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.

  Layout follows the questions an operator asks, in order: is the factory
  healthy, what needs a human, where is work flowing, what are agents doing,
  and what does it cost. Interactive parts (diagram, cost explorer) render
  client-side from one JSON payload so interactions never wait on the server.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, FactoryControls, IssueStage, Orchestrator, Tracker, UsageLedger}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.{Endpoint, FactoryPresenter, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  # Issue moves offered from the flow diagram: action => {Linear state, stage label}.
  @moves %{
    "approve" => {"In Progress", "merge"},
    "rework" => {"In Progress", "rework"},
    "block" => {"In Progress", "blocked"},
    "unblock" => {"In Progress", "implement"},
    "to_review" => {"In Review", nil}
  }

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:instance_name, SymphonyElixir.Config.instance_name())
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("factory_control", %{"stage" => stage, "field" => field} = params, socket) do
    reply =
      with :ok <- ensure_controls_enabled(),
           {:ok, controls} <- FactoryControls.put(stage, field, Map.get(params, "value")) do
        ObservabilityPubSub.broadcast_update()
        %{ok: true, controls: controls}
      else
        {:error, reason} -> %{ok: false, error: describe_error(reason)}
      end

    {:reply, reply, socket}
  end

  def handle_event("factory_move", %{"id" => id, "issue" => identifier, "action" => action} = params, socket)
      when is_binary(id) and is_binary(identifier) do
    reply =
      with :ok <- ensure_controls_enabled(),
           {:ok, {state_name, stage}} <- Map.fetch(@moves, action) |> move_or_error(action),
           :ok <- Tracker.set_stage(id, state_name, stage) do
        UsageLedger.observe_issue(%Issue{
          id: id,
          identifier: identifier,
          title: params["title"],
          url: params["url"],
          project_slug: params["project"],
          state: state_name,
          labels: if(stage, do: ["#{IssueStage.label_prefix()}/#{stage}"], else: [])
        })

        Orchestrator.request_refresh()
        ObservabilityPubSub.broadcast_update()
        %{ok: true}
      else
        {:error, reason} -> %{ok: false, error: describe_error(reason)}
      end

    {:reply, reply, socket}
  end

  defp ensure_controls_enabled do
    if FactoryPresenter.controls_enabled?(Config.settings!()), do: :ok, else: {:error, :controls_disabled}
  end

  defp move_or_error({:ok, move}, _action), do: {:ok, move}
  defp move_or_error(:error, action), do: {:error, {:unknown_action, action}}

  defp describe_error(:controls_disabled), do: "Controls are disabled. Set server.controls: true to allow changes."
  defp describe_error({:stage_label_not_found, label}), do: "Create the Linear label #{label} first."
  defp describe_error(:state_not_found), do: "That Linear state does not exist for this team."
  defp describe_error(reason), do: inspect(reason)

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="topbar">
        <div class="brand">
          <svg class="brand-mark" viewBox="0 0 32 32" aria-hidden="true">
            <path d="M6 22 L13 10 L19 18 L26 8" />
            <circle cx="6" cy="22" r="2.6" />
            <circle cx="13" cy="10" r="2.6" />
            <circle cx="19" cy="18" r="2.6" />
            <circle cx="26" cy="8" r="2.6" />
          </svg>
          <div>
            <h1 class="ops-title">
              <%= if @instance_name do %>
                <%= @instance_name %> Operations Dashboard
              <% else %>
                Operations Dashboard
              <% end %>
            </h1>
            <p class="ops-subtitle">Symphony agent factory</p>
          </div>
        </div>

        <div class="topbar-meta">
          <span class="status-badge status-badge-live">
            <span class="status-badge-dot"></span>
            Live
          </span>
          <span class="status-badge status-badge-offline">
            <span class="status-badge-dot"></span>
            Offline
          </span>
          <span :if={!@payload[:error]} class="meta-item numeric">
            <%= @payload.counts.running %>/<%= @payload.capacity.max_concurrent_agents %> agents
          </span>
          <span class="meta-item numeric"><%= polling_label(@payload[:polling]) %></span>
          <a class="meta-link" href="/api/v1/state">API</a>
          <a class="meta-link" href="/metrics">Metrics</a>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="panel error-panel">
          <h2 class="panel-title">Snapshot unavailable</h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <div
          :if={@payload[:factory]}
          id="factory-data"
          phx-hook="FactoryData"
          data-target="factory"
          data-json={Jason.encode!(@payload.factory)}
          hidden
        >
        </div>

        <section id="factory" class="factory" aria-label="Agent factory">
          <div id="fx-stats" class="fx-stats" data-fx="stats" phx-update="ignore"></div>

          <div class="factory-main">
            <section class="panel flow-panel">
              <div class="panel-head">
                <h2 class="panel-title">Flow</h2>
                <p class="panel-hint">Click a stage to pause it, cap it, pick its harness, or move its issues. Dashed arrows are loops.</p>
              </div>
              <div id="fx-diagram" data-fx="diagram" phx-update="ignore"></div>
            </section>

            <aside class="panel attention-panel" aria-label="Needs you">
              <div id="fx-drawer" class="fx-drawer-slot" data-fx="drawer" phx-update="ignore"></div>
              <div class="panel-head">
                <h2 class="panel-title">Needs you</h2>
                <span class={["count-pill", attention_count(@payload) > 0 && "count-pill-hot"]}>
                  <%= attention_count(@payload) %>
                </span>
              </div>

              <%= if attention_count(@payload) == 0 do %>
                <p class="all-clear">All clear. Nothing is waiting on a human.</p>
              <% else %>
                <div :for={group <- attention_groups(@payload, @now)} class="attention-group">
                  <h3 class="attention-title">
                    <span class={"attention-icon attention-icon-#{group.tone}"} aria-hidden="true"><%= group.icon %></span>
                    <%= group.title %>
                    <span class="attention-count numeric"><%= length(group.items) %></span>
                  </h3>
                  <a
                    :for={item <- Enum.take(group.items, 5)}
                    class="attention-item"
                    href={item.href}
                    target={if item.external, do: "_blank"}
                    rel={if item.external, do: "noopener"}
                  >
                    <span class="attention-id"><%= item.id %></span>
                    <span class="attention-text" title={item.text}><%= item.text %></span>
                    <span class="attention-age numeric"><%= item.age %></span>
                  </a>
                  <p :if={length(group.items) > 5} class="attention-more">+<%= length(group.items) - 5 %> more</p>
                </div>
              <% end %>
            </aside>
          </div>
        </section>

        <section class="panel">
          <div class="panel-head">
            <h2 class="panel-title">Live sessions</h2>
            <span class="panel-hint numeric">
              <%= @payload.counts.running %> running · <%= @payload.counts.retrying %> retrying · Runtime <%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %>
            </span>
          </div>

          <%= if issue_rows(@payload) == [] do %>
            <p class="empty-state">No agents are working right now.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Stage</th>
                    <th>Harness</th>
                    <th class="num">Runtime</th>
                    <th>Agent update</th>
                    <th class="num">Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- issue_rows(@payload)} class={entry.status == :retrying && "row-retrying"}>
                    <td>
                      <div class="issue-cell">
                        <a class="issue-id" href={entry.issue_url || "/api/v1/#{entry.issue_identifier}"}>
                          <%= entry.issue_identifier %>
                        </a>
                        <span class="issue-title" title={entry.issue_title}><%= entry.issue_title || "Untitled issue" %></span>
                        <span class="issue-project"><%= project_label(entry) %></span>
                      </div>
                    </td>
                    <td>
                      <span class={"stage-chip stage-#{stage_of(entry)}"}><%= stage_label(entry) %></span>
                    </td>
                    <td>
                      <div class="harness-cell">
                        <span class={"harness-dot h-#{entry.backend}"}></span>
                        <span><%= harness_label(entry.backend) %></span>
                        <span class="muted"><%= format_effort(entry.effort) %></span>
                      </div>
                      <div class="session-cell">
                        <span class="muted"><%= account_label(entry) %></span>
                        <button
                          :if={entry[:session_id]}
                          type="button"
                          class="copy-button"
                          data-label="Copy ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      </div>
                    </td>
                    <td class="num numeric"><%= row_runtime(entry, @now) %></td>
                    <td>
                      <div class="update-cell">
                        <span class="update-text" title={entry[:error] || entry[:last_message] || to_string(entry[:last_event] || "n/a")}>
                          <%= entry[:error] || entry[:last_message] || to_string(entry[:last_event] || "n/a") %>
                        </span>
                        <span class="muted update-meta">
                          <%= entry[:last_event] || "n/a" %>
                          <%= if entry[:last_event_at] do %>
                            · <%= relative_time(entry.last_event_at, @now) %>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td class="num">
                      <div class="token-cell numeric">
                        <span><%= format_compact(token_value(entry, :total_tokens)) %></span>
                        <span class="muted">
                          <%= format_compact(token_value(entry, :input_tokens)) %> in · <%= format_compact(token_value(entry, :output_tokens)) %> out
                        </span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="panel">
          <div class="panel-head">
            <h2 class="panel-title">Spend</h2>
            <p class="panel-hint">By project, team, or task, split by harness. Hover a bar for input and output tokens.</p>
          </div>
          <div id="fx-explorer" data-fx="explorer" phx-update="ignore"></div>
        </section>

        <footer class="ops-footer">
          <div class="footer-group">
            <span class="footer-label">Accounts</span>
            <span :for={account <- @payload.accounts} class={"footer-chip account-#{state_class_suffix(account.state)}"}>
              <span class="footer-dot"></span>
              <%= account.label %> · <%= account.state %>
              <%= if account[:daily_token_budget] do %>
                · <span class="numeric"><%= account[:daily_budget_percent] || 0 %>%</span>
              <% end %>
            </span>
            <span :if={@payload.accounts == []} class="muted">host auth</span>
          </div>

          <div class="footer-group">
            <span class="footer-label">Rate limits</span>
            <span :for={bucket <- global_rate_buckets(@payload.rate_limits)} class="footer-chip">
              <%= bucket.bucket %> <strong class="numeric"><%= format_limit_bucket(bucket) %></strong>
            </span>
            <span :if={global_rate_buckets(@payload.rate_limits) == []} class="muted">no snapshot</span>
          </div>

          <div class="footer-group">
            <span class="footer-label">Telemetry</span>
            <span class="muted">
              <%= if @payload.telemetry.enabled do %>
                OTLP → <%= telemetry_endpoint(@payload.telemetry) || "default" %>
              <% else %>
                off
              <% end %>
            </span>
          </div>

          <details class="footer-details">
            <summary>Raw rate-limit snapshot</summary>
            <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
          </details>
        </footer>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  # ------------------------------------------------------------- needs you

  defp attention_groups(payload, now) do
    nodes = factory_nodes(payload)

    [
      %{
        title: "Waiting for review",
        tone: "review",
        icon: "◐",
        items: nodes |> Map.get("review", []) |> Enum.sort_by(& &1.since_ms) |> Enum.map(&flow_item(&1, now))
      },
      %{
        title: "Blocked",
        tone: "critical",
        icon: "⏸",
        items: nodes |> Map.get("blocked", []) |> Enum.sort_by(& &1.since_ms) |> Enum.map(&flow_item(&1, now))
      },
      %{
        title: "Retrying",
        tone: "warning",
        icon: "↻",
        items: Enum.map(payload.retrying, &retry_item/1)
      },
      %{
        title: "Account trouble",
        tone: "critical",
        icon: "!",
        items:
          payload.accounts
          |> Enum.filter(&(state_class_suffix(&1.state) in ["limited", "danger", "paused"]))
          |> Enum.map(&account_item/1)
      }
    ]
    |> Enum.reject(&(&1.items == []))
  end

  defp attention_count(payload) do
    payload
    |> attention_groups(DateTime.utc_now())
    |> Enum.reduce(0, &(length(&1.items) + &2))
  end

  defp factory_nodes(%{factory: %{flow: %{nodes: nodes}}}) do
    Map.new(nodes, &{&1.id, &1.issues})
  end

  defp factory_nodes(_payload), do: %{}

  defp flow_item(issue, now) do
    %{
      id: issue.issue,
      text: issue.title || "",
      age: age_from_ms(issue.since_ms, now),
      href: issue[:url] || "/api/v1/#{issue.issue}",
      external: is_binary(issue[:url])
    }
  end

  defp retry_item(entry) do
    %{
      id: entry.issue_identifier,
      text: entry[:error] || "retry #{entry[:attempt]}",
      age: "#{entry[:attempt]}×",
      href: entry[:issue_url] || "/api/v1/#{entry.issue_identifier}",
      external: is_binary(entry[:issue_url])
    }
  end

  defp account_item(account) do
    %{
      id: account.backend,
      text: "#{account.label}: #{account[:failure_reason] || account.state}",
      age: if(account[:latest_reset_at], do: "reset", else: ""),
      href: "/api/v1/state",
      external: false
    }
  end

  defp age_from_ms(ms, now) when is_integer(ms) do
    format_age(DateTime.to_unix(now, :millisecond) - ms)
  end

  defp age_from_ms(_ms, _now), do: ""

  defp relative_time(iso, now) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> format_age(DateTime.diff(now, at, :millisecond)) <> " ago"
      _ -> iso
    end
  end

  defp relative_time(_iso, _now), do: ""

  defp format_age(ms) when ms < 90_000, do: "#{max(div(ms, 1000), 0)}s"
  defp format_age(ms) when ms < 5_400_000, do: "#{div(ms, 60_000)}m"
  defp format_age(ms) when ms < 129_600_000, do: "#{div(ms, 3_600_000)}h"
  defp format_age(ms), do: "#{div(ms, 86_400_000)}d"

  # ------------------------------------------------------------- sessions

  defp completed_runtime_seconds(payload) do
    payload.agent_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} · #{turn_count} turns"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    hours = div(whole_seconds, 3600)
    mins = div(rem(whole_seconds, 3600), 60)
    secs = rem(whole_seconds, 60)

    if hours > 0, do: "#{hours}h #{mins}m", else: "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_compact(value) when is_integer(value) and value >= 1_000_000, do: "#{Float.round(value / 1_000_000, 1)}M"
  defp format_compact(value) when is_integer(value) and value >= 10_000, do: "#{round(value / 1_000)}k"
  defp format_compact(value) when is_integer(value) and value >= 1_000, do: "#{Float.round(value / 1_000, 1)}k"
  defp format_compact(value) when is_integer(value), do: Integer.to_string(value)
  defp format_compact(_value), do: "–"

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(value) when is_float(value), do: value |> round() |> format_int()
  defp format_int(_value), do: "n/a"

  defp issue_rows(%{running: running, retrying: retrying}) do
    Enum.map(running, &Map.put(&1, :status, :running)) ++
      Enum.map(retrying, &Map.put(&1, :status, :retrying))
  end

  defp issue_rows(_payload), do: []

  defp row_runtime(%{status: :retrying} = entry, _now) do
    "retry #{Map.get(entry, :attempt) || 0}"
  end

  defp row_runtime(entry, now) do
    format_runtime_and_turns(Map.get(entry, :started_at), Map.get(entry, :turn_count), now)
  end

  defp stage_of(%{status: :retrying}), do: "retrying"

  defp stage_of(entry) do
    issue = %Issue{state: Map.get(entry, :state), labels: Map.get(entry, :labels) || []}

    IssueStage.stage(issue) ||
      entry |> Map.get(:state) |> to_string() |> String.downcase() |> String.replace(" ", "-")
  end

  defp stage_label(entry) do
    case stage_of(entry) do
      "" -> "–"
      stage -> stage |> String.replace("-", " ") |> String.capitalize()
    end
  end

  defp harness_label("codex"), do: "Codex"
  defp harness_label("claude"), do: "Claude Code"
  defp harness_label("opencode"), do: "OpenCode"
  defp harness_label(nil), do: "–"
  defp harness_label(other), do: other

  defp format_limit_bucket(%{limit: limit, remaining: remaining}) when is_integer(limit) and is_integer(remaining) do
    "#{format_int(remaining)} / #{format_int(limit)}"
  end

  defp format_limit_bucket(%{remaining: remaining}) when is_integer(remaining), do: "#{format_int(remaining)} left"
  defp format_limit_bucket(_bucket), do: "n/a"

  defp token_value(entry, key) do
    entry
    |> Map.get(:tokens, %{})
    |> map_value(key)
    |> case do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  defp account_label(entry) do
    cond do
      is_binary(Map.get(entry, :account_email)) and entry.account_email != "" -> entry.account_email
      is_binary(Map.get(entry, :account_id)) and entry.account_id != "" -> entry.account_id
      true -> "host auth"
    end
  end

  defp project_label(entry) do
    cond do
      is_binary(Map.get(entry, :project_name)) and entry.project_name != "" -> entry.project_name
      is_binary(Map.get(entry, :project_slug)) and entry.project_slug != "" -> entry.project_slug
      true -> "Unassigned project"
    end
  end

  defp format_effort(nil), do: "default"
  defp format_effort(""), do: "default"
  defp format_effort(effort), do: effort

  defp state_class_suffix(state) do
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["healthy", "active"]) -> "healthy"
      String.contains?(normalized, ["limited"]) -> "limited"
      String.contains?(normalized, ["paused", "disabled"]) -> "paused"
      String.contains?(normalized, ["exhausted", "failed", "error"]) -> "danger"
      true -> "unknown"
    end
  end

  defp telemetry_endpoint(telemetry) do
    Map.get(telemetry, :otlp_metrics_endpoint) || Map.get(telemetry, :otlp_endpoint)
  end

  defp polling_label(%{next_poll_in_ms: next_poll_in_ms}) when is_integer(next_poll_in_ms) do
    seconds = div(max(next_poll_in_ms, 0) + 999, 1_000)
    "Next poll #{seconds}s"
  end

  defp polling_label(%{checking?: true}), do: "Polling now"
  defp polling_label(_polling), do: "Polling n/a"

  defp global_rate_buckets(rate_limits) when is_map(rate_limits) do
    [
      {"session", map_value(rate_limits, :session) || map_value(rate_limits, :primary)},
      {"weekly", map_value(rate_limits, :weekly) || map_value(rate_limits, :secondary)}
    ]
    |> Enum.filter(fn {_name, bucket} -> is_map(bucket) end)
    |> Enum.map(fn {name, bucket} ->
      limit = integer_or_nil(map_value(bucket, :limit))
      remaining = integer_or_nil(map_value(bucket, :remaining))
      %{bucket: name, limit: limit, remaining: remaining}
    end)
  end

  defp global_rate_buckets(_rate_limits), do: []

  defp map_value(nil, _key), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(value) when is_float(value), do: round(value)

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp integer_or_nil(_value), do: nil

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
