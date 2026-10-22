defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.

  Layout follows the questions an operator asks, in order: is the factory
  working and is any agent stuck or blocked, where is work flowing and what
  needs a human, and which sessions ran. The top bar's team and project
  pickers scope all of it except the agent count, which is Symphony-wide. The
  flow diagram renders client-side from one JSON payload so interactions never
  wait on the server. Cost and traces live on the traces and metrics page.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias Phoenix.LiveView.JS
  import SymphonyElixirWeb.ChatPanel
  import SymphonyElixirWeb.Topbar
  require Logger

  alias SymphonyElixir.{AgentInbox, Auth, Config, FactoryControls, IssueMoves, IssueStage, McpTokens, Policy}
  alias SymphonyElixir.Factory.{Definition, Store}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{ProjectRoutes, SessionHistory, Transcript}
  alias SymphonyElixir.Users
  alias SymphonyElixirWeb.{Endpoint, FactoryPresenter, ObservabilityPubSub, Overview, Presenter, QuickLinks}
  alias SymphonyElixirWeb.ScopePicker
  alias SymphonyElixirWeb.{UserAuth, Visibility}
  @runtime_tick_ms 1_000
  # Ended sessions change only when a run ends; they're re-read this often
  # rather than on every orchestrator update.
  @ended_refresh_ms 10_000
  # Orchestrator updates arrive once per agent event; a page re-reads the
  # snapshot at most this often (`:dashboard_refresh_interval_ms` overrides it).
  @min_refresh_interval_ms 1_000
  @session_views ["live", "completed", "all"]
  @session_windows [{"day", "Last 24 hours", 86_400_000}, {"week", "Last 7 days", 7 * 86_400_000}, {"month", "Last 30 days", 30 * 86_400_000}]
  @max_ended_rows 200

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:instance_name, SymphonyElixir.Config.instance_name())
      |> assign(:team_filter, nil)
      |> assign(:project_filter, nil)
      |> assign(:refreshing, false)
      |> assign(:refresh_again, false)
      |> assign(:refresh_timer, nil)
      |> assign(:last_refresh_ms, nil)
      |> assign(:payload_gen, 0)
      |> assign(:sessions_view, "live")
      |> assign(:sessions_window, "day")
      |> assign(:sessions_query, "")
      |> assign(:approval_error, nil)
      |> assign(:bell_open, false)
      |> assign(:chat_issue, nil)
      |> assign(:chat_entries, [])
      |> assign(:chat_queued, [])
      |> assign(:chat_error, nil)
      |> assign(:chat_expanded, false)
      |> assign(:ended, [])
      |> assign(:mcp_setup, first_visit_mcp_setup(socket.assigns[:current_user]))
      # handle_params/3 loads the payload, once the URL's team and project are known.
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
      Process.send_after(self(), :refresh_ended, @ended_refresh_ms)
    end

    {:ok, socket}
  end

  # `?team=PAY` narrows the whole dashboard to one team's work and projects;
  # `?project=checkout` to one project's.
  # A pick re-scopes the payload the page already has rather than waiting on
  # a new orchestrator snapshot; live updates keep that payload fresh.
  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :scope_params, Map.take(params, ["team", "project", "flow"]))
    socket = if socket.assigns[:visible], do: assign_scope(socket), else: assign_payload(socket)
    {:noreply, assign_ended(socket)}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info(:refresh_ended, socket) do
    Process.send_after(self(), :refresh_ended, @ended_refresh_ms)
    {:noreply, assign_ended(socket)}
  end

  @impl true
  def handle_info(:observability_updated, socket), do: {:noreply, request_refresh(socket)}

  def handle_info(:refresh_due, socket), do: {:noreply, socket |> assign(:refresh_timer, nil) |> request_refresh()}

  @impl true
  def handle_event("factory_control", %{"team" => team, "stage" => stage, "field" => field} = params, socket) do
    reply =
      with :ok <- authorize(socket, {:edit_flow, team}),
           {:ok, controls} <- FactoryControls.put({team, stage}, field, Map.get(params, "value"), actor(socket)) do
        ObservabilityPubSub.broadcast_update()
        %{ok: true, controls: controls}
      else
        {:error, reason} -> %{ok: false, error: describe_error(reason)}
      end

    {:reply, reply, socket}
  end

  # Only the issue id and target stage come from the browser. The issue (team,
  # title, url, project, current stage) is read back from the tracker, and the
  # move must be a connection in that team's flow.
  def handle_event("factory_move", %{"id" => id, "to" => to}, socket) when is_binary(id) and is_binary(to) do
    reply =
      case move_issue(socket, id, to) do
        :ok -> %{ok: true}
        {:error, reason} -> %{ok: false, error: describe_error(reason)}
      end

    {:reply, reply, socket}
  end

  # A held issue: the agent already made its move. Approving keeps it (and
  # counts toward the stage's earned autonomy); sending back returns the issue
  # to the stage the agent moved it from (and resets that count).
  def handle_event(verdict, %{"id" => id}, socket) when verdict in ["approve_issue", "send_back_issue"] and is_binary(id) do
    case review_issue(socket, id, if(verdict == "approve_issue", do: :approved, else: :sent_back)) do
      :ok -> {:noreply, assign(socket, :approval_error, nil)}
      {:error, reason} -> {:noreply, assign(socket, :approval_error, describe_error(reason))}
    end
  end

  # Earned autonomy for a flow: every agent stage needs approval until it has
  # `streak` approvals in a row.
  def handle_event("factory_autopilot", %{"team" => scope, "enabled" => enabled, "streak" => streak}, socket)
      when is_binary(scope) and is_boolean(enabled) and is_integer(streak) do
    reply =
      with :ok <- authorize(socket, {:edit_flow, scope}),
           {:ok, saved} <- Store.put_autopilot(scope, enabled, streak, actor(socket)) do
        ObservabilityPubSub.broadcast_update()
        %{ok: true, definition: saved}
      else
        {:error, [message | _]} -> %{ok: false, error: message}
        {:error, reason} -> %{ok: false, error: describe_error(reason)}
      end

    {:reply, reply, socket}
  end

  # The chat-style transcript of an issue's agents, if the viewer can see it.
  def handle_event("open_chat", %{"id" => identifier}, socket) when is_binary(identifier) do
    if Visibility.filter_issue(%{}, socket.assigns.current_user, identifier) == :hidden,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(chat_issue: identifier, chat_error: nil) |> assign_chat()}
  end

  def handle_event("close_chat", _params, socket), do: {:noreply, assign(socket, chat_issue: nil, chat_entries: [], chat_queued: [])}
  def handle_event("toggle_chat_size", _params, socket), do: {:noreply, assign(socket, :chat_expanded, !socket.assigns.chat_expanded)}

  # A message to the agent on the open issue: Codex takes it mid-turn, other
  # agents at their next turn (AgentInbox).
  def handle_event("send_message", %{"text" => text}, socket) do
    user = socket.assigns.current_user
    issue = socket.assigns.chat_issue

    cond do
      is_nil(issue) ->
        {:noreply, socket}

      not can_message?(user, socket.assigns.payload, issue) ->
        {:noreply, assign(socket, :chat_error, "You can't message this agent.")}

      true ->
        case AgentInbox.send_message(issue, text, author_name(user)) do
          {:ok, _message} -> {:noreply, socket |> assign(:chat_error, nil) |> assign_chat() |> push_event("chat_sent", %{})}
          {:error, reason} -> {:noreply, assign(socket, :chat_error, message_error(reason))}
        end
    end
  end

  # Removes the picked project from Symphony (`ProjectRoutes.remove/2`): no
  # longer polled, routed or listed; its history stays. Admins and admins of a
  # team it belongs to.
  def handle_event("remove_project", %{"project" => slug}, socket) when is_binary(slug) do
    with :ok <- authorize(socket, {:remove_project, slug}),
         :ok <- ProjectRoutes.remove(slug, actor(socket)) do
      SymphonyElixir.Orchestrator.request_refresh_async()
      ObservabilityPubSub.broadcast_update()
      team = socket.assigns.team_filter
      {:noreply, push_patch(socket, to: if(team, do: "/?team=" <> team, else: "/"))}
    else
      {:error, reason} -> {:noreply, assign(socket, :approval_error, describe_error(reason))}
    end
  end

  # The flow panel's MCP button: flows are edited from a coding agent, so it
  # opens the same setup popup as the first visit. Looking only, so read-only
  # people may open it too.
  def handle_event("open_mcp_setup", _params, socket) do
    case mcp_setup(socket.assigns.current_user) do
      nil -> {:reply, %{ok: false, error: "MCP needs a signed-in account and server.mcp.enabled."}, socket}
      setup -> {:reply, %{ok: true}, assign(socket, :mcp_setup, setup)}
    end
  end

  def handle_event("dismiss_mcp_setup", _params, socket) do
    case socket.assigns.current_user do
      %Auth.User{local: false, id: id} -> Users.mark_mcp_welcomed(id)
      _local -> :ok
    end

    {:noreply, assign(socket, :mcp_setup, nil)}
  end

  def handle_event("toggle_bell", _params, socket), do: {:noreply, assign(socket, :bell_open, !socket.assigns.bell_open)}
  def handle_event("close_bell", _params, socket), do: {:noreply, assign(socket, :bell_open, false)}

  def handle_event("pick_team", %{"team" => _team} = params, socket) do
    query = params |> ScopePicker.pick(socket.assigns.team_filter) |> URI.encode_query()
    {:noreply, push_patch(socket, to: if(query == "", do: "/", else: "/?" <> query))}
  end

  # Session filters never wait on the orchestrator: switching the view only
  # re-picks rows, and the window or a search re-reads ended sessions.
  def handle_event("sessions_view", %{"view" => view}, socket) when view in @session_views do
    {:noreply, socket |> assign(:sessions_view, view) |> assign_sessions()}
  end

  # The window select is disabled while it doesn't apply, and then not sent.
  def handle_event("sessions_filter", params, socket) do
    window = if Enum.any?(@session_windows, &(elem(&1, 0) == params["window"])), do: params["window"], else: socket.assigns.sessions_window
    query = params |> Map.get("query", socket.assigns.sessions_query) |> to_string() |> String.trim() |> String.slice(0, 120)
    {:noreply, socket |> assign(sessions_window: window, sessions_query: query) |> assign_ended()}
  end

  @impl true
  def handle_async(:refresh, {:ok, fetched}, socket) do
    socket = assign(socket, :refreshing, false)

    # A read that started before a change made from this page is stale.
    socket =
      if fetched.gen == socket.assigns.payload_gen do
        socket
        |> assign(now: DateTime.utc_now())
        |> assign_fetched_chat(fetched.chat)
        |> assign_snapshot(fetched.snapshot)
        |> assign_scope()
      else
        socket
      end

    {:noreply, if(socket.assigns.refresh_again, do: request_refresh(socket), else: socket)}
  end

  def handle_async(:refresh, {:exit, _reason}, socket) do
    socket = assign(socket, :refreshing, false)
    {:noreply, if(socket.assigns.refresh_again, do: request_refresh(socket), else: socket)}
  end

  # IssueMoves checks the person may move the issue once it knows its team.
  defp review_issue(socket, id, verdict) do
    with {:ok, user} <- authorize(socket, :write) |> with_user(socket) do
      IssueMoves.review(user, id, verdict, actor: actor(socket))
    end
  end

  defp move_issue(socket, id, to) do
    with {:ok, user} <- authorize(socket, :write) |> with_user(socket) do
      IssueMoves.move(user, id, to, actor: actor(socket))
    end
  end

  defp with_user(:ok, socket), do: UserAuth.refresh_user(socket)
  defp with_user(error, _socket), do: error

  defp actor(socket), do: socket.assigns.current_user.username || "local"

  # Server enforces every permission (SymphonyElixir.Policy); the client only
  # hides what the user can't use. Checks against a freshly resolved user, so a
  # disabled account or a lost Linear role can't keep acting from a page opened
  # earlier.
  defp authorize(socket, action) do
    with true <- FactoryPresenter.controls_enabled?(Config.settings!()) || {:error, :controls_disabled},
         {:ok, user} <- UserAuth.refresh_user(socket) do
      Policy.authorize(user, action)
    end
  end

  # Per-user view of the factory payload: what this person may change, and
  # team names from their Linear memberships.
  defp factory_json(factory, user, scope, overview) do
    enabled? = FactoryPresenter.controls_enabled?(Config.settings!())
    names = Map.new(user.teams, &{&1.key, &1.name})
    factory = with_overview_flow(factory, overview)
    # The all-teams flow is derived from Linear states: nothing in it is edited.
    editable = Map.new(factory.teams, &{&1.key, enabled? and &1[:kind] != "overview" and Policy.can?(user, {:edit_flow, &1.key})})

    factory
    |> Map.delete(:overview)
    |> Map.update!(:teams, fn teams -> Enum.map(teams, &Map.put(&1, :name, &1.name || names[&1.key])) end)
    |> Map.put(:controls_enabled, enabled? and Policy.can?(user, :control))
    |> Map.put(:movable_teams, if(enabled?, do: Policy.movable_teams(user), else: []))
    |> Map.put(:movable_projects, if(enabled?, do: Policy.movable_projects(user), else: []))
    |> Map.put(:can_edit, editable)
    |> Map.put(:can_control, editable)
    # The flow the top bar's team or project picks.
    |> Map.put(:scope, scope)
    |> Jason.encode!()
  end

  defp with_overview_flow(factory, nil), do: factory

  defp with_overview_flow(factory, %{entry: entry, definition: definition, flow: flow}) do
    %{
      factory
      | teams: [entry | factory.teams],
        definitions: Map.put(factory.definitions, entry.key, definition),
        flows: Map.put(factory.flows, entry.key, flow)
    }
  end

  defp quick_links(true, _visible, _team, _project), do: %{linear: nil, repos: []}
  defp quick_links(false, visible, team, project), do: QuickLinks.for_scope(visible, team, project)

  # The picked project, else every listed one, that is closing in Linear.
  defp closing_projects(choices, picked) do
    Enum.filter(choices, &(&1[:closing] && (is_nil(picked) or &1.slug == picked)))
  end

  defp can_remove_project?(user, slug) do
    FactoryPresenter.controls_enabled?(Config.settings!()) and Policy.can?(user, {:remove_project, slug})
  end

  defp project_name(choices, slug), do: Enum.find_value(choices, slug, &(&1.slug == slug && &1.name))

  defp flow_title(true, _overview?), do: "Default flow"
  defp flow_title(_default?, true), do: "Flow · all teams by Linear state"
  defp flow_title(_default?, _overview?), do: "Flow"

  defp describe_error(reason), do: IssueMoves.describe_error(reason)

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <.topbar
        instance_name={@instance_name}
        current_user={@current_user}
        teams={@team_choices}
        team={@team_filter}
        projects={@project_choices}
        project={@project_filter}
      >
        <span class="status-badge status-badge-live">
          <span class="status-badge-dot"></span>
          Live
        </span>
        <span class="status-badge status-badge-offline">
          <span class="status-badge-dot"></span>
          Offline
        </span>
        <span :if={!@payload[:error]} class="meta-item meta-agents numeric" title="Agents running across all of Symphony / agent slots">
          <%= @symphony_counts.running %>/<%= @payload.capacity.max_concurrent_agents %> agents
        </span>
        <span class="meta-item meta-poll numeric"><%= polling_label(@payload[:polling]) %></span>
        <span :if={get_in(@payload, [:delayed_restart, :pending])} class="meta-item status-badge-offline" title="No new agent runs start until Symphony restarts">
          Restart pending: waiting for <%= @payload.delayed_restart.waiting_for %> agent(s)
        </span>
        <div :if={!@payload[:error]} class="bell" phx-click-away="close_bell">
          <button
            type="button"
            class={["bell-button", approvals(@payload, @now) != [] && "has-items"]}
            phx-click="toggle_bell"
            aria-expanded={to_string(@bell_open)}
            aria-label={"#{length(approvals(@payload, @now))} waiting for your approval"}
            title="Waiting for your approval"
          >
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15L6 16Z" /><path d="M10 20a2 2 0 0 0 4 0" /></svg>
            <span :if={approvals(@payload, @now) != []} class="bell-count numeric"><%= length(approvals(@payload, @now)) %></span>
          </button>
          <div :if={@bell_open} class="bell-panel" role="menu">
            <p class="bell-title">Waiting for your approval</p>
            <p :if={approvals(@payload, @now) == []} class="bell-empty">Nothing is waiting. Approvals show up here.</p>
            <div :for={item <- approvals(@payload, @now)} class="bell-item">
              <div class="bell-item-head">
                <a :if={item.href} class="attention-id" href={item.href} target="_blank" rel="noopener"><%= item.id %></a>
                <span :if={!item.href} class="attention-id"><%= item.id %></span>
                <span class="bell-item-title" title={item.text}><%= item.text %></span>
                <span class="attention-age numeric"><%= item.age %></span>
              </div>
              <p class="approval-move"><%= item.from_name || "?" %> → <strong><%= item.stage %></strong></p>
              <div class="approval-actions">
                <a :if={item.href} class="fx-link-btn" href={item.href} target="_blank" rel="noopener">Read the ticket ↗</a>
                <%= if Policy.can?(@current_user, {:move_issue, item.id, item.project}) do %>
                  <button type="button" class="fx-action" phx-click="send_back_issue" phx-value-id={item.issue_id} disabled={is_nil(item.from_name)}>
                    ↩ Send back
                  </button>
                  <button type="button" class="fx-action is-primary" phx-click="approve_issue" phx-value-id={item.issue_id}>
                    ✓ Approve
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </.topbar>

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
          data-json={factory_json(@payload.factory, @current_user, @flow_scope, @overview)}
          hidden
        >
        </div>

        <section id="factory" class="factory" aria-label="Agent factory">
          <div id="health" class="fx-stats health-strip" aria-label="Is the factory working">
            <%= for tile <- health_tiles(@payload, @symphony_counts, @now) do %>
              <a :if={tile[:href]} class={["fx-stat", "health-#{tile.tone}"]} href={tile.href}>
                <.health_tile tile={tile} />
              </a>
              <div :if={!tile[:href]} class={["fx-stat", "health-#{tile.tone}"]}>
                <.health_tile tile={tile} />
              </div>
            <% end %>
          </div>

          <div class="factory-main">
            <section class="panel flow-panel">
              <div class="panel-head">
                <h2 class="panel-title">{flow_title(@default_flow?, @overview?)}</h2>
                <p :if={@overview?} class="panel-hint">
                  Every team you can see, by Linear state: what Symphony is working on, and where it's up to. Pick a team or project at the top for its own flow.
                  <a :if={@default_visible?} href="/?flow=default">Default flow →</a>
                </p>
                <p :if={!@default_flow? and !@overview?} class="panel-hint">Click a stage to manage it or move its issues. Solid lines are agent moves, dotted lines are person moves.</p>
                <p :if={@default_flow?} class="panel-hint">
                  Every team without its own flow follows this one, and so does every team added later. Admins edit it from a coding agent over MCP (save_flow, scope DEFAULT).
                  <a href="/">← All teams</a>
                </p>
              </div>
              <p :for={p <- closing_projects(@project_choices, @project_filter)} class="fx-closing" role="status">
                <strong>{p.name}</strong>
                closing in Linear ({p.closing.reason}) — {p.closing.in_progress} {if p.closing.in_progress == 1, do: "issue", else: "issues"} still in progress.
                Nothing new starts; it leaves Symphony once they're done.
              </p>
              <nav :if={@quick_links.linear || @quick_links.repos != []} class="fx-quick-links" aria-label="Links">
                <a :if={@quick_links.linear} class="fx-link-chip is-linear" href={@quick_links.linear.url} target="_blank" rel="noopener">
                  {@quick_links.linear.label} ↗
                </a>
                <a :for={repo <- @quick_links.repos} class="fx-link-chip is-repo" href={repo.url} target="_blank" rel="noopener" title="GitHub repo">
                  {repo.label} ↗
                </a>
                <button
                  :if={@project_filter && can_remove_project?(@current_user, @project_filter)}
                  type="button"
                  class="fx-link-chip is-remove"
                  phx-click="remove_project"
                  phx-value-project={@project_filter}
                  data-confirm={"Remove #{project_name(@project_choices, @project_filter)} from Symphony? It stops being polled and leaves the project list; its history is kept. Nothing changes in Linear or GitHub. An admin can add it back over MCP (add_project)."}
                >
                  Remove project
                </button>
              </nav>
              <div id="fx-diagram" data-fx="diagram" phx-update="ignore"></div>
            </section>

            <aside id="needs-you" class="panel attention-panel" aria-label="Needs you">
              <div id="fx-drawer" class="fx-drawer-slot" data-fx="drawer" phx-update="ignore"></div>
              <div class="panel-head">
                <h2 class="panel-title">Needs you</h2>
                <span class={["count-pill", attention_count(@payload) > 0 && "count-pill-hot"]}>
                  <%= attention_count(@payload) %>
                </span>
              </div>

              <p :if={@approval_error} class="attention-more" role="alert"><%= @approval_error %></p>

              <%= if attention_count(@payload) == 0 do %>
                <p class="all-clear">All clear. Nothing is waiting on a human.</p>
              <% else %>
                <div :if={approvals(@payload, @now) != []} class="attention-group">
                  <h3 class="attention-title">
                    <span class="attention-icon attention-icon-review" aria-hidden="true">✋</span>
                    Waiting for your approval
                    <span class="attention-count numeric"><%= length(approvals(@payload, @now)) %></span>
                  </h3>
                  <div :for={item <- approvals(@payload, @now)} class="attention-item approval-item">
                    <a :if={item.href} class="attention-id" href={item.href} target="_blank" rel="noopener"><%= item.id %></a>
                    <span :if={!item.href} class="attention-id"><%= item.id %></span>
                    <span class="attention-text" title={item.text}><%= item.text %></span>
                    <span class="attention-age numeric"><%= item.age %></span>
                    <p class="approval-move"><%= item.from_name || "?" %> → <strong><%= item.stage %></strong></p>
                    <div class="approval-actions">
                      <a :if={item.href} class="fx-link-btn" href={item.href} target="_blank" rel="noopener">Read the ticket ↗</a>
                      <button type="button" class="fx-link-btn" phx-click="open_chat" phx-value-id={item.id}>💬 Transcript</button>
                      <%= if Policy.can?(@current_user, {:move_issue, item.id, item.project}) do %>
                        <button type="button" class="fx-action" phx-click="send_back_issue" phx-value-id={item.issue_id} disabled={is_nil(item.from_name)}>
                          ↩ Send back
                        </button>
                        <button type="button" class="fx-action is-primary" phx-click="approve_issue" phx-value-id={item.issue_id}>
                          ✓ Approve
                        </button>
                      <% end %>
                    </div>
                  </div>
                </div>

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

        <section id="sessions" class="panel">
          <div class="panel-head">
            <h2 class="panel-title">Sessions</h2>
            <span class="panel-hint numeric">
              <%= @payload.counts.running %> running · <%= @payload.counts.retrying %> retrying · Runtime <%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %>
            </span>
          </div>

          <form id="sessions-filter" class="sessions-controls" phx-change="sessions_filter" phx-submit="sessions_filter">
            <div class="fx-seg" role="radiogroup" aria-label="Which sessions">
              <button
                :for={{value, label} <- [{"live", "Live"}, {"completed", "Completed"}, {"all", "All"}]}
                type="button"
                class={["fx-seg-btn", @sessions_view == value && "is-active"]}
                role="radio"
                aria-checked={to_string(@sessions_view == value)}
                phx-click="sessions_view"
                phx-value-view={value}
              >
                <%= label %>
                <span class="muted numeric"><%= @session_counts[value] %></span>
              </button>
            </div>
            <select
              id="sessions-window"
              name="window"
              class="sessions-window dd-native"
              tabindex="-1"
              phx-hook="Dropdown"
              data-dropdown-slot="sessions-window-dd"
              aria-label="Completed in"
              disabled={@sessions_view == "live" or @sessions_query != ""}
              title={if @sessions_query != "", do: "Search covers every kept session"}
            >
              <option :for={{value, label, _ms} <- session_windows()} value={value} selected={value == @sessions_window}><%= label %></option>
            </select>
            <span id="sessions-window-dd" class="dd" phx-update="ignore"></span>
            <input
              type="search"
              name="query"
              class="fx-search"
              value={@sessions_query}
              placeholder="Search by title or ID, e.g. PAY-142"
              aria-label="Search sessions by issue title or ID"
              autocomplete="off"
              phx-debounce="250"
            />
          </form>

          <%= if @sessions == [] do %>
            <p class="empty-state"><%= empty_sessions_copy(@sessions_view, @sessions_query, @sessions_window) %></p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table sessions-table">
                <colgroup>
                  <col class="col-issue" />
                  <col class="col-stage" />
                  <col class="col-harness" />
                  <col class="col-runtime" />
                  <col class="col-update" />
                  <col class="col-tokens" />
                </colgroup>
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
                  <tr
                    :for={entry <- @sessions}
                    :key={entry.row_key}
                    class={[
                      entry.status == :retrying && "row-retrying",
                      entry.status == :ended && "row-ended",
                      stuck?(entry, @now) && "row-stuck"
                    ]}
                  >
                    <td>
                      <div class="issue-cell">
                        <a class="issue-id" href={safe_url(entry.issue_url) || "/api/v1/#{entry.issue_identifier}"}>
                          <%= entry.issue_identifier %>
                        </a>
                        <span class="issue-title" title={entry.issue_title}><%= entry.issue_title || "Untitled issue" %></span>
                        <span class="issue-project"><%= project_label(entry) %></span>
                        <button type="button" class="chat-open" phx-click="open_chat" phx-value-id={entry.issue_identifier}>
                          <%= if entry.status == :ended, do: "💬 Transcript", else: "💬 Watch the agent" %>
                        </button>
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
                      <div :if={entry[:model] && entry[:model] != "default"} class="muted model-cell" title="Model"><%= entry[:model] %></div>
                      <div class="session-cell">
                        <span :if={entry.status != :ended} class="muted"><%= account_label(entry) %></span>
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
                        <span class="update-text" title={update_text(entry)}>
                          <span class={"outcome-chip outcome-#{outcome_class(entry, @now)}"}><%= outcome_label(entry, @now) %></span><%= update_text(entry) %>
                        </span>
                        <span :if={stuck?(entry, @now)} class="stuck-note">No update for <%= quiet_for(entry, @now) %></span>
                        <span class="muted update-meta">
                          <%= if entry.status == :ended do %>
                            Ended <%= relative_time(entry.ended_at, @now) %>
                          <% else %>
                            <%= entry[:last_event] || "n/a" %>
                            <%= if entry[:last_event_at] do %>
                              · <%= relative_time(entry.last_event_at, @now) %>
                            <% end %>
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
            <p :if={@ended_overflow > 0} class="sessions-note">
              Showing the newest <%= max_ended_rows() %> ended sessions; <%= @ended_overflow %> more. Search to find one.
            </p>
          <% end %>
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

          <details id="rate-limit-details" class="footer-details" phx-mounted={JS.ignore_attributes(["open"])}>
            <summary>Raw rate-limit snapshot</summary>
            <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
          </details>
        </footer>
      <% end %>
      <.chat_panel
        :if={@chat_issue}
        issue={@chat_issue}
        entries={@chat_entries}
        queued={@chat_queued}
        session={chat_session(@payload, @chat_issue)}
        can_message={can_message?(@current_user, @payload, @chat_issue)}
        error={@chat_error}
        expanded={@chat_expanded}
      />

      <div :if={@mcp_setup} class="mcp-welcome" role="dialog" aria-modal="true" aria-labelledby="mcp-welcome-title">
        <div class="mcp-welcome-card">
          <h2 id="mcp-welcome-title" class="login-title">Connect your agents to Agent Factory</h2>
          <p class="login-help">
            Your coding agent can watch and steer Agent Factory over MCP with your personal token. It can do what you can do here.
            Pick your harness and run its step. You can find this again, or rotate the token, under <a href="/account/mcp">MCP setup</a>.
          </p>
          <SymphonyElixirWeb.McpSetup.instructions url={@mcp_setup.url} token={@mcp_setup.token} />
          <button type="button" class="login-button" phx-click="dismiss_mcp_setup">Done</button>
        </div>
      </div>
    </section>
    """
  end

  # The MCP setup opens once, on someone's first visit, and never in local mode.
  defp first_visit_mcp_setup(%Auth.User{local: false, id: id} = user) do
    case Users.get(id) do
      %{mcp_welcomed_at: nil} -> mcp_setup(user)
      _ -> nil
    end
  end

  defp first_visit_mcp_setup(_user), do: nil

  # The setup popup's URL and the person's own token; nil in local mode (no
  # account, so no token) or with MCP off.
  defp mcp_setup(%Auth.User{local: false, id: id}) do
    with true <- Config.settings!().server.mcp.enabled == true,
         {:ok, secret, _token} <- McpTokens.current(id) do
      %{url: SymphonyElixirWeb.McpSetup.url(Endpoint.url()), token: secret}
    else
      _ -> nil
    end
  end

  defp mcp_setup(_user), do: nil

  # The pickers offer the teams and projects this person can see (a chosen
  # team's projects only); an unknown or hidden one in the URL falls back to
  # all. The agent count stays Symphony-wide: slots are shared by everyone.
  defp assign_payload(socket) do
    user = socket.assigns[:current_user]

    socket
    |> update(:payload_gen, &(&1 + 1))
    |> assign_chat()
    |> assign_snapshot(snapshot(user))
    |> assign_scope()
  end

  # Server updates come in bursts and a snapshot waits on the orchestrator,
  # so they're read off the LiveView process (which stays free for picks and
  # clicks), one at a time, with updates that arrive meanwhile folded into one
  # more read.
  # Reads are also spaced at least the refresh interval apart: with a large
  # fleet a snapshot covers every run and updates never stop, so an update
  # inside the interval waits for one deferred read.
  defp request_refresh(%{assigns: %{refreshing: true}} = socket), do: assign(socket, :refresh_again, true)
  defp request_refresh(%{assigns: %{refresh_timer: timer}} = socket) when is_reference(timer), do: socket

  defp request_refresh(socket) do
    case refresh_wait_ms(socket.assigns[:last_refresh_ms]) do
      0 -> refresh_payload(socket)
      wait_ms -> assign(socket, :refresh_timer, Process.send_after(self(), :refresh_due, wait_ms))
    end
  end

  defp refresh_wait_ms(nil), do: 0

  defp refresh_wait_ms(last_refresh_ms) do
    interval_ms = Application.get_env(:symphony_elixir, :dashboard_refresh_interval_ms, @min_refresh_interval_ms)
    max(interval_ms - (System.monotonic_time(:millisecond) - last_refresh_ms), 0)
  end

  defp refresh_payload(socket) do
    %{current_user: user, chat_issue: issue, payload_gen: gen} = socket.assigns

    socket
    |> assign(refreshing: true, refresh_again: false, last_refresh_ms: System.monotonic_time(:millisecond))
    |> start_async(:refresh, fn ->
      %{gen: gen, snapshot: snapshot(user), chat: {issue, chat_data(issue)}}
    end)
  end

  defp snapshot(user) do
    teams = if user, do: Enum.map(user.teams, & &1.key), else: []
    raw = Presenter.state_payload(orchestrator(), snapshot_timeout_ms(), teams: teams)
    # The visible payload is kept unrendered for re-scoping; the counts are the Symphony-wide ones.
    %{visible: Visibility.filter_payload(raw, user), symphony_counts: raw[:counts] || %{running: 0, retrying: 0}}
  end

  defp assign_snapshot(socket, %{visible: visible, symphony_counts: counts}),
    do: assign(socket, visible: visible, symphony_counts: counts)

  defp assign_scope(socket) do
    %{visible: visible, current_user: user} = socket.assigns

    %{team: team, project: project, teams: choices, projects: projects} =
      ScopePicker.resolve(socket.assigns[:scope_params] || %{}, visible, user)

    payload =
      if project,
        do: Visibility.scope_to_project(visible, project),
        else: Visibility.scope_to_team(visible, team)

    all? = is_nil(team) and is_nil(project)
    default? = all? and default_flow?(socket.assigns[:scope_params], visible)

    socket
    |> assign(:team_choices, choices)
    |> assign(:team_filter, team)
    |> assign(:project_choices, projects)
    |> assign(:project_filter, project)
    |> assign(:flow_scope, if(default?, do: Store.default_team(), else: ScopePicker.flow_scope(team, project)))
    |> assign(:default_flow?, default?)
    |> assign(:default_visible?, default_visible?(visible))
    |> assign(:payload, payload)
    |> assign(:overview?, all? and not default? and multi_team?(user, choices))
    |> assign(:quick_links, quick_links(default?, visible, team, project))
    |> assign_overview()
    |> assign_sessions()
  end

  # `?flow=default` opens the default flow (every team without its own
  # follows it), for those who can see it.
  defp default_flow?(%{"flow" => flow}, visible) when is_binary(flow), do: String.downcase(flow) == "default" and default_visible?(visible)
  defp default_flow?(_params, _visible), do: false

  defp default_visible?(%{factory: %{teams: entries}}), do: Enum.any?(entries, &(&1[:kind] == "default"))
  defp default_visible?(_visible), do: false

  # Someone who sees every team, or several, lands on the overview; one team
  # (picked, or the only one someone has) shows that team's flow.
  defp multi_team?(user, choices), do: Policy.visible_teams(user) == :all or length(choices) > 1

  # All teams and all projects: the flow drawn is the Linear-state one
  # (`SymphonyElixirWeb.Overview`), across the teams the viewer can see.
  defp assign_overview(%{assigns: %{overview?: true}} = socket) do
    %{payload: payload, team_choices: choices} = socket.assigns
    rows = get_in(payload, [:factory, :overview]) || []
    socket |> assign(:overview, Overview.flow(rows, team_keys: Enum.map(choices, & &1.key))) |> assign(:flow_scope, Overview.scope())
  end

  defp assign_overview(socket), do: assign(socket, :overview, nil)

  # Ended sessions in the chosen window (counted even on the live view), for
  # the viewer and the picked team or project; a search looks through all.
  defp assign_ended(socket) do
    %{sessions_query: query, sessions_window: window, current_user: user} = socket.assigns

    sessions =
      if query != "" do
        SessionHistory.list()
      else
        {_value, _label, ms} = Enum.find(@session_windows, &(elem(&1, 0) == window))
        SessionHistory.list(since_ms: System.system_time(:millisecond) - ms)
      end

    ended =
      sessions
      |> Visibility.filter_sessions(user)
      |> Visibility.scope_sessions(socket.assigns.team_filter, socket.assigns.project_filter)
      |> Enum.map(&Map.put(&1, :status, :ended))

    socket |> assign(:ended, ended) |> assign_sessions()
  end

  # Live sessions first, then ended ones newest first; a search matches the
  # issue ID or title. Worked out once per change, not per template use.
  defp assign_sessions(socket) do
    %{payload: payload, ended: ended, sessions_view: view, sessions_query: query} = socket.assigns
    live = issue_rows(payload)
    matched = matching(ended, query)
    shown_ended = if view in ["completed", "all"], do: Enum.take(matched, @max_ended_rows), else: []

    socket
    |> assign(:sessions, with_row_keys(if(view in ["live", "all"], do: matching(live, query), else: []) ++ shown_ended))
    |> assign(:ended_overflow, if(view in ["completed", "all"], do: max(length(matched) - @max_ended_rows, 0), else: 0))
    |> assign(:session_counts, %{"live" => length(live), "completed" => length(ended), "all" => length(live) + length(ended)})
  end

  defp assign_chat(socket), do: assign_chat_data(socket, chat_data(socket.assigns[:chat_issue]))

  # A transcript read for an issue that's no longer open is dropped.
  defp assign_fetched_chat(socket, {issue, data}) do
    if issue == socket.assigns.chat_issue, do: assign_chat_data(socket, data), else: socket
  end

  defp assign_chat_data(socket, {entries, queued}), do: assign(socket, chat_entries: entries, chat_queued: queued)

  defp chat_data(nil), do: {[], []}
  defp chat_data(issue), do: {Transcript.entries(issue), Enum.filter(AgentInbox.messages(issue), &(&1.status == "queued"))}

  # The open issue's running entry, for the chat header.
  defp chat_session(%{running: running}, identifier) when is_list(running) do
    case Enum.find(running, &(&1.issue_identifier == identifier)) do
      nil -> nil
      entry -> Map.put(entry, :stage, stage_label(entry))
    end
  end

  defp chat_session(_payload, _identifier), do: nil

  # Messaging an agent is a change to its work: the viewer must see the issue
  # and hold the right to move it.
  defp can_message?(user, _payload, identifier) do
    Visibility.filter_issue(%{}, user, identifier) != :hidden and Policy.can?(user, {:message_agent, identifier, nil})
  end

  defp author_name(user), do: user.name || user.username || user.email || "someone"

  defp message_error(:empty_message), do: "Write a message first."
  defp message_error(:message_too_long), do: "That message is too long (8,000 characters at most)."
  defp message_error(:unavailable), do: "Messaging isn't available right now."
  defp message_error(reason), do: "Couldn't send: #{inspect(reason)}"

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  # ------------------------------------------------------------- health

  attr(:tile, :map, required: true)

  defp health_tile(assigns) do
    ~H"""
    <span class="fx-stat-label"><span class="health-dot" aria-hidden="true"></span><%= @tile.label %></span>
    <strong :if={@tile[:word]} class="fx-stat-value health-word"><%= @tile.word %></strong>
    <strong :if={!@tile[:word]} class="fx-stat-value" id={"health-#{@tile.id}"} phx-hook="DotMatrix" data-value={@tile.value} aria-label={@tile.value}></strong>
    <span class="fx-stat-detail"><%= @tile.detail %></span>
    """
  end

  # Is the factory working, and is any agent stuck or blocked. Agents counts
  # every running agent; the rest follows the team and project pickers.
  defp health_tiles(payload, symphony_counts, now) do
    stuck = stuck_entries(payload, now)
    parked = issues_in_kind(payload, "parked")
    retrying = Enum.reject(payload.retrying, &stalled_retry?/1)
    troubled = troubled_accounts(payload)
    approvals = approvals(payload, now)
    waiting = issues_in_kind(payload, "human")
    blocked = length(parked) + length(retrying) + length(troubled)
    needs_you = length(approvals) + length(waiting)

    [
      system_tile(payload, troubled),
      %{
        id: "agents",
        label: "Agents",
        tone: if(symphony_counts.running > 0, do: "good", else: "idle"),
        value: "#{symphony_counts.running}/#{payload.capacity.max_concurrent_agents}",
        detail: "running across Symphony · #{symphony_counts.retrying} retrying"
      },
      %{
        id: "stuck",
        label: "Stuck",
        tone: if(stuck == [], do: "good", else: "bad"),
        value: to_string(length(stuck)),
        detail: if(stuck == [], do: "every agent is reporting in", else: Enum.map_join(Enum.take(stuck, 3), ", ", & &1.id)),
        href: "#needs-you"
      },
      %{
        id: "blocked",
        label: "Blocked",
        tone: if(blocked == 0, do: "good", else: "warn"),
        value: to_string(blocked),
        detail: if(blocked == 0, do: "nothing parked or retrying", else: blocked_detail(parked, retrying, troubled)),
        href: "#needs-you"
      },
      %{
        id: "needs-you",
        label: "Needs you",
        tone: if(needs_you == 0, do: "good", else: "warn"),
        value: to_string(needs_you),
        detail: if(needs_you == 0, do: "nothing waiting on a person", else: "#{length(approvals)} to approve · #{length(waiting)} waiting on people"),
        href: "#needs-you"
      }
    ]
  end

  defp system_tile(payload, troubled) do
    accounts = payload.accounts
    restart? = get_in(payload, [:delayed_restart, :pending])

    {tone, word, detail} =
      cond do
        accounts != [] and length(troubled) == length(accounts) -> {"bad", "Down", "no agent account can run"}
        restart? -> {"warn", "Restarting", "waiting for #{payload.delayed_restart.waiting_for} agent(s) to finish"}
        troubled != [] -> {"warn", "Degraded", "#{length(troubled)} agent account(s) limited or failing"}
        is_nil(payload[:polling]) -> {"warn", "Unknown", "no poll has run yet"}
        true -> {"good", "Working", poll_detail(payload.polling)}
      end

    %{id: "system", label: "System", tone: tone, word: word, detail: detail}
  end

  defp poll_detail(%{poll_interval_ms: interval} = polling) when is_integer(interval),
    do: "polls Linear every #{format_age(interval)} · #{String.downcase(polling_label(polling))}"

  defp poll_detail(polling), do: polling_label(polling)

  defp blocked_detail(parked, retrying, troubled) do
    [{length(parked), "parked"}, {length(retrying), "retrying"}, {length(troubled), "account trouble"}]
    |> Enum.reject(&(elem(&1, 0) == 0))
    |> Enum.map_join(" · ", fn {n, what} -> "#{n} #{what}" end)
  end

  defp troubled_accounts(payload), do: Enum.filter(payload.accounts, &(state_class_suffix(&1.state) in ["limited", "danger", "paused"]))

  # An agent is stuck once it has been quiet for half its harness's stall
  # timeout (Symphony restarts it at the full timeout), or Symphony restarted
  # it for stalling and it is waiting to retry.
  defp stuck_entries(payload, now) do
    quiet =
      payload.running
      |> Enum.map(&Map.put(&1, :status, :running))
      |> Enum.filter(&stuck?(&1, now))
      |> Enum.map(&%{id: &1.issue_identifier, text: "No update for #{quiet_for(&1, now)} · #{update_text(&1)}", age: quiet_for(&1, now), entry: &1})

    stalled =
      for entry <- payload.retrying, stalled_retry?(entry) do
        %{id: entry.issue_identifier, text: "Restarted after stalling; retry #{entry[:attempt]}", age: "#{entry[:attempt]}×", entry: entry}
      end

    quiet ++ stalled
  end

  defp stalled_retry?(entry), do: is_binary(entry[:error]) and String.starts_with?(entry[:error], "stalled")

  defp stuck?(%{status: :running} = entry, now) do
    case quiet_ms(entry, now) do
      ms when is_integer(ms) -> ms > stuck_after_ms(entry[:backend])
      _ -> false
    end
  end

  defp stuck?(_entry, _now), do: false

  defp stuck_after_ms(backend) do
    case Config.agent_stall_timeout_ms(backend) do
      ms when is_integer(ms) and ms > 0 -> div(ms, 2)
      _ -> 600_000
    end
  end

  defp quiet_ms(entry, now) do
    with iso when is_binary(iso) <- entry[:last_event_at] || entry[:started_at],
         {:ok, at, _offset} <- DateTime.from_iso8601(iso) do
      DateTime.diff(now, at, :millisecond)
    else
      _ -> nil
    end
  end

  defp quiet_for(entry, now), do: entry |> quiet_ms(now) |> then(&if(is_integer(&1), do: format_age(&1), else: "a while"))

  # ------------------------------------------------------------- needs you

  defp attention_groups(payload, now) do
    [
      %{
        title: "Stuck",
        tone: "critical",
        icon: "⧗",
        items: payload |> stuck_entries(now) |> Enum.map(&stuck_item/1)
      },
      %{
        title: "Waiting on people",
        tone: "review",
        icon: "◐",
        items: payload |> issues_in_kind("human") |> Enum.sort_by(& &1.since_ms) |> Enum.map(&flow_item(&1, now))
      },
      %{
        title: "Parked",
        tone: "critical",
        icon: "⏸",
        items: payload |> issues_in_kind("parked") |> Enum.sort_by(& &1.since_ms) |> Enum.map(&flow_item(&1, now))
      },
      %{
        title: "Retrying",
        tone: "warning",
        icon: "↻",
        items: payload.retrying |> Enum.reject(&stalled_retry?/1) |> Enum.map(&retry_item/1)
      },
      %{
        title: "Account trouble",
        tone: "critical",
        icon: "!",
        items: payload |> troubled_accounts() |> Enum.map(&account_item/1)
      }
    ]
    |> Enum.reject(&(&1.items == []))
  end

  defp attention_count(payload) do
    payload
    |> attention_groups(DateTime.utc_now())
    |> Enum.reduce(length(approvals(payload, DateTime.utc_now())), &(length(&1.items) + &2))
  end

  # Issues sitting in stages of a kind (human, parked) across every visible team.
  defp issues_in_kind(%{factory: %{definitions: definitions, flows: flows}}, kind) do
    Enum.flat_map(definitions, fn {team, definition} ->
      definition["stages"]
      |> Enum.filter(&(&1["kind"] == kind))
      |> Enum.flat_map(&get_in(flows, [team, :nodes, &1["id"], :issues]))
    end)
    # A project that inherits its team's flow shows the same issues as the team.
    |> Enum.uniq_by(& &1.issue)
  end

  defp issues_in_kind(_payload, _kind), do: []

  # Issues an agent moved out of a stage that needs approval: they wait at the
  # stage the agent chose, for a person to approve or send back.
  defp approvals(%{factory: %{definitions: definitions, flows: flows}}, now) do
    definitions
    |> Enum.flat_map(fn {scope, definition} ->
      Enum.flat_map(definition["stages"], fn stage ->
        (get_in(flows, [scope, :nodes, stage["id"], :issues]) || [])
        |> Enum.filter(& &1[:awaiting])
        |> Enum.map(&approval_item(&1, stage, definition, now))
      end)
    end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.since_ms)
  end

  defp approvals(_payload, _now), do: []

  defp approval_item(issue, stage, definition, now) do
    # Held issues are listed under the stage they're leaving; `to` is the move.
    {stage, from} =
      case Definition.stage(definition, issue[:to]) do
        %{} = target -> {target, stage}
        nil -> {stage, Definition.stage(definition, issue[:from])}
      end

    issue
    |> flow_item(now)
    |> Map.merge(%{
      issue_id: issue[:id],
      project: issue[:project],
      stage: stage["name"],
      from_name: from && from["name"],
      since_ms: issue.since_ms,
      href: safe_url(issue[:url])
    })
  end

  defp flow_item(issue, now) do
    %{
      id: issue.issue,
      text: issue.title || "",
      age: age_from_ms(issue.since_ms, now),
      href: safe_url(issue[:url]) || "/api/v1/#{issue.issue}",
      external: is_binary(safe_url(issue[:url]))
    }
  end

  defp stuck_item(%{id: id, text: text, age: age, entry: entry}) do
    %{
      id: id,
      text: text,
      age: age,
      href: safe_url(entry[:issue_url]) || "/api/v1/#{id}",
      external: is_binary(safe_url(entry[:issue_url]))
    }
  end

  defp retry_item(entry) do
    %{
      id: entry.issue_identifier,
      text: entry[:error] || "retry #{entry[:attempt]}",
      age: "#{entry[:attempt]}×",
      href: safe_url(entry[:issue_url]) || "/api/v1/#{entry.issue_identifier}",
      external: is_binary(safe_url(entry[:issue_url]))
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

  # Only https links are rendered, so stored values can never become javascript: URLs.
  defp safe_url("https://" <> _rest = url), do: url
  defp safe_url(_url), do: nil

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

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp issue_rows(%{running: running, retrying: retrying}) do
    Enum.map(running, &Map.put(&1, :status, :running)) ++
      Enum.map(retrying, &Map.put(&1, :status, :retrying))
  end

  defp issue_rows(_payload), do: []

  # A stable, unique key per row, so the keyed comprehension sends only the
  # rows that changed instead of the whole table on every update.
  @doc false
  @spec with_row_keys([map()]) :: [map()]
  def with_row_keys(rows) do
    {keyed, _seen} =
      Enum.map_reduce(rows, %{}, fn row, seen ->
        base = Enum.map_join([row[:status], row[:issue_identifier], row[:ended_at]], ":", &to_string/1)
        count = Map.get(seen, base, 0)
        key = if count == 0, do: base, else: base <> "#" <> Integer.to_string(count)
        {Map.put(row, :row_key, key), Map.put(seen, base, count + 1)}
      end)

    keyed
  end

  defp session_windows, do: @session_windows
  defp max_ended_rows, do: @max_ended_rows

  defp matching(rows, ""), do: rows

  defp matching(rows, query) do
    q = String.downcase(query)
    Enum.filter(rows, fn row -> Enum.any?([row.issue_identifier, row[:issue_title]], &(is_binary(&1) and String.contains?(String.downcase(&1), q))) end)
  end

  defp empty_sessions_copy(_view, query, _window) when query != "", do: "No sessions match “#{query}”."
  defp empty_sessions_copy("live", _query, _window), do: "No agents are working right now."

  defp empty_sessions_copy(_view, _query, window) do
    {_value, label, _ms} = Enum.find(@session_windows, &(elem(&1, 0) == window))
    "No sessions in the #{String.downcase(label)}."
  end

  defp update_text(entry), do: entry[:error] || entry[:last_message] || to_string(entry[:last_event] || "n/a")

  defp outcome_class(%{status: :ended} = entry, _now), do: entry.outcome
  defp outcome_class(%{status: :retrying}, _now), do: "retrying"
  defp outcome_class(entry, now), do: if(stuck?(entry, now), do: "stuck", else: "running")

  defp outcome_label(%{status: :ended} = entry, _now) do
    case entry.outcome do
      "finished" -> "Finished"
      "crashed" -> "Crashed"
      "stalled" -> "Stalled"
      "closed" -> "Issue closed"
      "paused" -> "Paused"
      "moved" -> "Issue moved on"
      "missing" -> "Issue gone"
      other -> other
    end
  end

  defp outcome_label(%{status: :retrying}, _now), do: "Retrying"
  defp outcome_label(entry, now), do: if(stuck?(entry, now), do: "Stuck", else: "Running")

  defp row_runtime(%{status: :ended} = entry, _now) do
    runtime = format_runtime_seconds(entry.runtime_seconds || 0)
    if (entry[:turn_count] || 0) > 0, do: "#{runtime} · #{entry.turn_count} turns", else: runtime
  end

  defp row_runtime(%{status: :retrying} = entry, _now) do
    "retry #{Map.get(entry, :attempt) || 0}"
  end

  defp row_runtime(entry, now) do
    format_runtime_and_turns(Map.get(entry, :started_at), Map.get(entry, :turn_count), now)
  end

  defp stage_of(%{status: :retrying}), do: "retrying"
  defp stage_of(%{status: :ended} = entry), do: entry[:stage_id] || "ended"

  defp stage_of(entry) do
    case session_stage(entry) do
      %{"id" => id} -> id
      nil -> entry |> Map.get(:state) |> to_string() |> String.downcase() |> String.replace(" ", "-")
    end
  end

  # The identifier carries the team and the project slug picks a project's own
  # flow; together they decide which flow, and so which stage, the issue is in.
  defp session_stage(entry) do
    IssueStage.stage_definition(%Issue{
      identifier: Map.get(entry, :issue_identifier),
      project_slug: Map.get(entry, :project_slug),
      state: Map.get(entry, :state),
      labels: Map.get(entry, :labels) || []
    })
  end

  defp stage_label(%{status: :retrying}), do: "Retrying"
  defp stage_label(%{status: :ended} = entry), do: entry[:stage] || entry[:state] || "–"

  defp stage_label(entry) do
    case session_stage(entry) do
      %{"name" => name} -> name
      nil -> entry |> Map.get(:state) |> to_string() |> then(&if(&1 == "", do: "–", else: &1))
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
