defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

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
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="ops-header">
        <div class="identity-block">
          <p class="eyebrow">
            <%= if @instance_name do %>
              <%= @instance_name %>
            <% else %>
              Symphony Observability
            <% end %>
          </p>
          <h1 class="ops-title">
            <%= if @instance_name do %>
              <%= @instance_name %> Operations Dashboard
            <% else %>
              Operations Dashboard
            <% end %>
          </h1>
          <div class="header-meta">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
            <span class="meta-divider"></span>
            <span class="meta-item mono numeric"><%= @payload[:generated_at] || "snapshot pending" %></span>
            <span class="meta-item"><%= polling_label(@payload[:polling]) %></span>
          </div>
        </div>

        <nav class="header-actions" aria-label="Dashboard links">
          <a class="icon-link" href="/api/v1/state" title="State JSON" aria-label="State JSON">
            {}
          </a>
        </nav>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-panel">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="overview-strip">
          <div class="metric-cell">
            <p class="metric-label">Sessions</p>
            <p class="metric-value numeric">
              <%= @payload.counts.running %><span>/<%= @payload.capacity.max_concurrent_agents %></span>
            </p>
            <p class="metric-detail">Running now</p>
          </div>

          <div class="metric-cell">
            <p class="metric-label">Retry pressure</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Backoff queue</p>
          </div>

          <div class="metric-cell">
            <p class="metric-label">Tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.agent_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.agent_totals.input_tokens) %> / Out <%= format_int(@payload.agent_totals.output_tokens) %>
            </p>
          </div>

          <div class="metric-cell">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Completed + active</p>
          </div>

          <div class="metric-cell metric-cell-wide">
            <p class="metric-label">Thinking mix</p>
            <p class="metric-value metric-value-text"><%= effort_summary(@payload.running) %></p>
            <p class="metric-detail">Current running sessions</p>
          </div>
        </section>

        <section class="ops-grid">
          <section class="section-panel">
            <div class="section-header">
              <div>
                <h2 class="section-title">Accounts</h2>
                <p class="section-copy">Usage, active sessions, and per-account limit pressure.</p>
              </div>
              <span class="section-count numeric"><%= length(@payload.accounts) %></span>
            </div>

            <%= if @payload.accounts == [] do %>
              <p class="empty-state">No configured accounts or account-bound sessions.</p>
            <% else %>
              <div class="account-list">
                <article :for={account <- @payload.accounts} class="account-row">
                  <div class="account-main">
                    <span class={account_state_class(account.state)}></span>
                    <div class="account-copy">
                      <h3><%= account.label %></h3>
                      <p>
                        <%= account.backend %> · <%= account.id %>
                        <%= if account.worker_host do %>
                          · <%= account.worker_host %>
                        <% end %>
                      </p>
                    </div>
                    <span class={account_badge_class(account.state)}><%= account.state %></span>
                  </div>

                  <div class="account-usage">
                    <div class="usage-line">
                      <span>Total tokens</span>
                      <strong class="numeric"><%= format_int(account.total_tokens) %></strong>
                    </div>
                    <div class="usage-line">
                      <span>Running</span>
                      <strong class="numeric"><%= account.running_count %></strong>
                    </div>
                  </div>

                  <div class="budget-grid">
                    <div class="budget-item">
                      <div class="budget-label">
                        <span>Daily</span>
                        <span class="numeric"><%= format_budget(account.daily_tokens, account.daily_token_budget) %></span>
                      </div>
                      <div class="meter-track">
                        <span class="meter-fill meter-fill-account" style={percent_width(account.daily_budget_percent)}></span>
                      </div>
                    </div>

                    <div class="budget-item">
                      <div class="budget-label">
                        <span>Monthly</span>
                        <span class="numeric"><%= format_budget(account.monthly_tokens, account.monthly_token_budget) %></span>
                      </div>
                      <div class="meter-track">
                        <span class="meter-fill meter-fill-account" style={percent_width(account.monthly_budget_percent)}></span>
                      </div>
                    </div>
                  </div>

                  <div class="limit-list">
                    <span :for={bucket <- account.rate_limit_buckets} class="limit-chip">
                      <%= bucket.bucket %>
                      <strong class="numeric"><%= format_limit_bucket(bucket) %></strong>
                    </span>
                    <span :if={account.rate_limit_buckets == []} class="muted">No limit snapshot</span>
                    <span :if={account.latest_reset_at} class="limit-reset mono numeric">
                      reset <%= account.latest_reset_at %>
                    </span>
                  </div>

                  <p :if={account.failure_reason} class="account-note">
                    <%= account.failure_reason %>
                  </p>
                </article>
              </div>
            <% end %>
          </section>

          <section class="section-panel">
            <div class="section-header">
              <div>
                <h2 class="section-title">Projects</h2>
                <p class="section-copy">Configured routes and the issues currently attached to each project.</p>
              </div>
              <span class="section-count numeric"><%= length(@payload.projects) %></span>
            </div>

            <%= if @payload.projects == [] do %>
              <p class="empty-state">No configured projects.</p>
            <% else %>
              <div class="project-list">
                <article :for={project <- @payload.projects} class={project_row_class(project)}>
                  <div class="project-head">
                    <div>
                      <h3><%= project.name %></h3>
                      <p>
                        <%= project.slug || "no Linear project" %>
                        <%= if project.backend do %>
                          · <%= project.backend %>
                        <% end %>
                      </p>
                    </div>
                    <div class="project-numbers">
                      <span><strong class="numeric"><%= project.issue_count %></strong> issues</span>
                      <span><strong class="numeric"><%= project.running_count %></strong> running</span>
                      <span><strong class="numeric"><%= project.retrying_count %></strong> retrying</span>
                    </div>
                  </div>

                  <div class="project-progress">
                    <div class="meter-track">
                      <span class="meter-fill" style={project_activity_width(project)}></span>
                    </div>
                    <span class="numeric"><%= format_int(project.total_tokens) %> tokens</span>
                  </div>

                  <div class="project-issues">
                    <a
                      :for={issue <- Enum.take(project.issues, 5)}
                      class="issue-pill"
                      href={issue_href(issue)}
                      title={issue.issue_title || issue.issue_identifier || "Issue"}
                    >
                      <span><%= issue.issue_identifier || "unknown" %></span>
                      <span class={progress_tone_class(issue.progress)}><%= issue.progress.label %></span>
                    </a>
                    <span :if={project.issues == []} class="muted">No active issue sessions</span>
                  </div>
                </article>
              </div>
            <% end %>
          </section>
        </section>

        <section class="section-panel">
          <div class="section-header">
            <div>
              <h2 class="section-title">Issue Progress</h2>
              <p class="section-copy">Active and retrying work with project, account, backend, effort, and last agent activity.</p>
            </div>
            <span class="section-count numeric"><%= length(issue_rows(@payload)) %></span>
          </div>

          <%= if issue_rows(@payload) == [] do %>
            <p class="empty-state">No active or retrying issues.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table issue-table">
                <colgroup>
                  <col style="width: 15rem;" />
                  <col style="width: 14rem;" />
                  <col style="width: 13rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Progress</th>
                    <th>Account / backend</th>
                    <th>Runtime</th>
                    <th>Agent update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- issue_rows(@payload)}>
                    <td>
                      <div class="issue-stack">
                        <a class="issue-id" href={entry.issue_url || "/api/v1/#{entry.issue_identifier}"}>
                          <%= entry.issue_identifier %>
                        </a>
                        <span class="issue-title"><%= entry.issue_title || "Untitled issue" %></span>
                        <span class="issue-link">
                          <%= project_label(entry) %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="progress-stack">
                        <div class="progress-heading">
                          <span class={state_badge_class(entry.state || entry.status)}>
                            <%= progress_label(entry) %>
                          </span>
                          <span class="numeric"><%= entry.progress.percent %>%</span>
                        </div>
                        <div class="meter-track">
                          <span class={progress_fill_class(entry.progress)} style={percent_width(entry.progress.percent)}></span>
                        </div>
                      </div>
                    </td>
                    <td>
                      <div class="account-cell">
                        <span><%= account_label(entry) %></span>
                        <span class="muted">
                          <%= entry.backend || "backend n/a" %> · <%= format_effort(entry.effort) %>
                        </span>
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="copy-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">No session</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= row_runtime(entry, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(token_value(entry, :total_tokens)) %></span>
                        <span class="muted">
                          In <%= format_int(token_value(entry, :input_tokens)) %> / Out <%= format_int(token_value(entry, :output_tokens)) %>
                        </span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="context-grid">
          <section class="section-panel">
            <div class="section-header">
              <div>
                <h2 class="section-title">Rate Limits</h2>
                <p class="section-copy">Latest global upstream snapshot, plus raw details for buckets not mapped to an account.</p>
              </div>
            </div>

            <div class="rate-summary">
              <span :for={bucket <- global_rate_buckets(@payload.rate_limits)} class="limit-chip limit-chip-large">
                <%= bucket.bucket %>
                <strong class="numeric"><%= format_limit_bucket(bucket) %></strong>
              </span>
              <span :if={global_rate_buckets(@payload.rate_limits) == []} class="muted">No global rate-limit snapshot.</span>
            </div>

            <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
          </section>

          <section class="section-panel">
            <div class="section-header">
              <div>
                <h2 class="section-title">OTLP Metrics</h2>
                <p class="section-copy">Telemetry exported by Codex and Claude sessions.</p>
              </div>
              <span class={telemetry_badge_class(@payload.telemetry.enabled)}>
                <%= if @payload.telemetry.enabled, do: "Enabled", else: "Disabled" %>
              </span>
            </div>

            <div class="telemetry-grid">
              <div>
                <span>Endpoint</span>
                <strong class="mono"><%= telemetry_endpoint(@payload.telemetry) || "n/a" %></strong>
              </div>
              <div>
                <span>Protocol</span>
                <strong><%= @payload.telemetry.otlp_metrics_protocol || @payload.telemetry.otlp_protocol || "n/a" %></strong>
              </div>
              <div>
                <span>Metrics</span>
                <strong><%= on_off(@payload.telemetry.include_metrics) %></strong>
              </div>
              <div>
                <span>Traces</span>
                <strong><%= on_off(@payload.telemetry.include_traces) %></strong>
              </div>
              <div>
                <span>Logs</span>
                <strong><%= on_off(@payload.telemetry.include_logs) %></strong>
              </div>
            </div>
          </section>
        </section>
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
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
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

  defp effort_summary([]), do: "No active efforts"

  defp effort_summary(running) do
    running
    |> Enum.frequencies_by(&(Map.get(&1, :effort) || "default"))
    |> Enum.sort_by(fn {effort, _count} -> effort end)
    |> Enum.map_join(" · ", fn {effort, count} -> "#{effort} #{count}" end)
  end

  defp row_runtime(%{status: :retrying} = entry, _now) do
    attempt = Map.get(entry, :attempt) || 0
    due_at = Map.get(entry, :due_at) || "n/a"
    "retry #{attempt} / #{due_at}"
  end

  defp row_runtime(entry, now) do
    format_runtime_and_turns(Map.get(entry, :started_at), Map.get(entry, :turn_count), now)
  end

  defp progress_label(entry) do
    case Map.get(entry, :progress) do
      %{label: label} when is_binary(label) and label != "" -> label
      %{"label" => label} when is_binary(label) and label != "" -> label
      _ -> Map.get(entry, :state) || to_string(Map.get(entry, :status) || "running")
    end
  end

  defp progress_fill_class(progress), do: "meter-fill progress-fill progress-fill-#{progress_tone(progress)}"

  defp progress_tone_class(progress), do: "progress-tone progress-tone-#{progress_tone(progress)}"

  defp progress_tone(%{tone: tone}) when is_binary(tone), do: tone
  defp progress_tone(%{"tone" => tone}) when is_binary(tone), do: tone
  defp progress_tone(_progress), do: "active"

  defp percent_width(nil), do: "width: 0%;"

  defp percent_width(value) when is_number(value) do
    value = value |> max(0) |> min(100)
    "width: #{value}%;"
  end

  defp percent_width(_value), do: "width: 0%;"

  defp format_budget(tokens, nil), do: format_int(tokens)
  defp format_budget(tokens, budget), do: "#{format_int(tokens)} / #{format_int(budget)}"

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
      true -> "Host auth"
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

  defp issue_href(%{issue_url: url}) when is_binary(url) and url != "", do: url

  defp issue_href(%{issue_identifier: identifier}) when is_binary(identifier) and identifier != "" do
    "/api/v1/#{identifier}"
  end

  defp issue_href(_issue), do: "/api/v1/state"

  defp project_row_class(project) do
    base = "project-row"

    cond do
      Map.get(project, :issue_count, 0) > 0 -> "#{base} project-row-active"
      Map.get(project, :configured?) -> "#{base} project-row-configured"
      true -> base
    end
  end

  defp project_activity_width(%{issues: issues}) when is_list(issues) and issues != [] do
    total =
      Enum.reduce(issues, 0, fn issue, sum ->
        progress = Map.get(issue, :progress) || %{}
        sum + (map_value(progress, :percent) || 0)
      end)

    percent = total / length(issues)
    percent_width(percent)
  end

  defp project_activity_width(_project), do: "width: 0%;"

  defp account_state_class(state) do
    "account-dot account-dot-#{state_class_suffix(state)}"
  end

  defp account_badge_class(state) do
    "account-badge account-badge-#{state_class_suffix(state)}"
  end

  defp telemetry_badge_class(true), do: "telemetry-badge telemetry-badge-on"
  defp telemetry_badge_class(_enabled), do: "telemetry-badge telemetry-badge-off"

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

  defp on_off(true), do: "on"
  defp on_off(_value), do: "off"

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

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
