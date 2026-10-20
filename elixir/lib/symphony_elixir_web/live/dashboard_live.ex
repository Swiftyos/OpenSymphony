defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.

  Layout follows the questions an operator asks, in order: is the factory
  healthy, what needs a human, where is work flowing, what are agents doing,
  and what does it cost. Interactive parts (diagram, cost explorer) render
  client-side from one JSON payload so interactions never wait on the server.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}
  import SymphonyElixirWeb.Topbar
  require Logger

  alias SymphonyElixir.{Auth, Config, FactoryControls, IssueStage, Orchestrator, Tracker, UsageLedger, Users}
  alias SymphonyElixir.Factory.{Assistant, Definition, Store}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.{Endpoint, FactoryPresenter, ObservabilityPubSub, Presenter, UserAuth, Visibility}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:instance_name, SymphonyElixir.Config.instance_name())
      |> assign(:team_filter, nil)
      |> assign(:approval_error, nil)
      |> assign_payload()
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  # `?team=PAY` narrows the whole dashboard to one team's work and projects.
  @impl true
  def handle_params(params, _uri, socket) do
    team = params |> Map.get("team") |> then(&(is_binary(&1) && String.upcase(String.trim(&1))))
    {:noreply, socket |> assign(:team_filter, team || nil) |> assign_payload()}
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
     |> assign_payload()
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("factory_control", %{"team" => team, "stage" => stage, "field" => field} = params, socket) do
    reply =
      with :ok <- authorize(socket, &Auth.can_edit_factory?(&1, team), :not_team_editor),
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
      with :ok <- authorize(socket, &Auth.can_edit_factory?(&1, scope), :not_team_editor),
           {:ok, saved} <- Store.put_autopilot(scope, enabled, streak, actor(socket)) do
        ObservabilityPubSub.broadcast_update()
        %{ok: true, definition: saved}
      else
        {:error, [message | _]} -> %{ok: false, error: message}
        {:error, reason} -> %{ok: false, error: describe_error(reason)}
      end

    {:reply, reply, socket}
  end

  def handle_event("factory_save", %{"team" => team, "version" => version, "definition" => definition}, socket)
      when is_binary(team) and is_integer(version) and is_map(definition) do
    reply =
      with :ok <- authorize(socket, &Auth.can_edit_factory?(&1, team), :not_team_editor),
           {:ok, saved} <- Store.put(team, definition, version, actor(socket)) do
        sync_stage_labels(team, saved)
        ObservabilityPubSub.broadcast_update()
        %{ok: true, definition: saved}
      else
        {:error, {:conflict, current}} -> %{ok: false, conflict: current}
        {:error, [_ | _] = errors} -> %{ok: false, errors: errors}
        {:error, reason} -> %{ok: false, errors: [describe_error(reason)]}
      end

    {:reply, reply, socket}
  end

  # Drafting runs the harness CLI (up to a few minutes), so it runs off the
  # LiveView process and the result is pushed back when it's ready.
  def handle_event("factory_assist", %{"team" => team, "stage" => stage, "request" => request} = params, socket)
      when is_binary(team) and is_binary(stage) do
    case authorize(socket, &Auth.can_edit_factory?(&1, team), :not_team_editor) do
      :ok ->
        ref = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
        definition = assist_definition(params["definition"], team)
        skill? = params["skill"] != false

        socket =
          start_async(socket, {:assist, ref}, fn -> Assistant.draft(definition, stage, request, skill: skill?) end)

        {:reply, %{ok: true, pending: true, ref: ref}, socket}

      {:error, reason} ->
        {:reply, %{ok: false, error: describe_error(reason)}, socket}
    end
  end

  # Drafts a whole flow for a scope (team, project, or the default) from a
  # description, starting from the editor's current draft.
  def handle_event("factory_assist_flow", %{"team" => scope, "request" => request} = params, socket) when is_binary(scope) do
    case authorize(socket, &Auth.can_edit_factory?(&1, scope), :not_team_editor) do
      :ok ->
        ref = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
        base = assist_definition(params["definition"], scope)

        opts = [
          scope_label: scope_label(scope),
          linear_states: known_states(base),
          label_prefix: IssueStage.label_prefix(),
          skills: params["skills"] != false
        ]

        socket = start_async(socket, {:assist, ref}, fn -> Assistant.draft_flow(base, request, opts) end)
        {:reply, %{ok: true, pending: true, ref: ref}, socket}

      {:error, reason} ->
        {:reply, %{ok: false, error: describe_error(reason)}, socket}
    end
  end

  # Drops a team's or project's own flow so it inherits again.
  def handle_event("factory_reset", %{"team" => scope}, socket) when is_binary(scope) do
    reply =
      with :ok <- authorize(socket, &Auth.can_edit_factory?(&1, scope), :not_team_editor),
           :ok <- Store.reset_team(scope) do
        ObservabilityPubSub.broadcast_update()
        %{ok: true}
      else
        {:error, reason} -> %{ok: false, error: describe_error(reason)}
      end

    {:reply, reply, socket}
  end

  def handle_event("pick_team", %{"team" => team}, socket) do
    to = if team in ["", "all"], do: "/", else: "/?" <> URI.encode_query(%{"team" => team})
    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("approve_account", %{"id" => id}, socket) do
    with :ok <- authorize(socket, &Auth.can_control?/1, :not_admin),
         {:ok, _account} <- Users.approve(id, socket.assigns.current_user.username || "local") do
      ObservabilityPubSub.broadcast_update()
    end

    {:noreply, socket}
  end

  def handle_event("reject_account", %{"id" => id}, socket) do
    with :ok <- authorize(socket, &Auth.can_control?/1, :not_admin),
         :ok <- Users.reject(id) do
      ObservabilityPubSub.broadcast_update()
    end

    {:noreply, socket}
  end

  @impl true
  def handle_async({:assist, ref}, {:ok, {:ok, suggestion}}, socket) do
    {:noreply, push_event(socket, "factory_assist_result", %{ref: ref, ok: true, suggestion: suggestion})}
  end

  def handle_async({:assist, ref}, {:ok, {:error, message}}, socket) do
    {:noreply, push_event(socket, "factory_assist_result", %{ref: ref, ok: false, error: message})}
  end

  def handle_async({:assist, ref}, {:exit, _reason}, socket) do
    {:noreply, push_event(socket, "factory_assist_result", %{ref: ref, ok: false, error: "The assistant stopped unexpectedly."})}
  end

  # The unsaved draft the editor is working on, if it's a valid definition;
  # otherwise the team's saved flow.
  defp assist_definition(%{} = draft, team) do
    case Definition.validate(draft) do
      {:ok, definition} -> definition
      {:error, _errors} -> Store.get(team)
    end
  end

  defp assist_definition(_draft, team), do: Store.get(team)

  defp scope_label("project:" <> slug), do: "the project #{get_in(UsageLedger.projects(), [slug, :name]) || slug}"
  defp scope_label(scope), do: if(scope == Store.default_team(), do: "the whole organisation (the default flow)", else: "the #{scope} team")

  defp known_states(definition) do
    settings = Config.settings!()

    (Enum.map(definition["stages"], & &1["linear_state"]) ++
       settings.tracker.active_states ++ ["In Review"] ++ settings.tracker.terminal_states)
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp review_issue(socket, id, verdict) do
    approval = IssueStage.approval_label()

    with :ok <- authorize(socket, fn _user -> true end, :signed_out),
         {:ok, %Issue{} = issue} <- fetch_movable_issue(id),
         :ok <- authorize(socket, &Auth.can_move_issue?(&1, issue.identifier, issue.project_slug), :not_team_member),
         true <- IssueStage.awaiting_approval?(issue) || {:error, :not_awaiting_approval},
         definition = IssueStage.definition(issue),
         %{} = from <- Definition.stage(definition, UsageLedger.previous_node(issue.identifier)) || {:error, :unknown_origin},
         target = if(verdict == :approved, do: IssueStage.stage_definition(issue), else: from),
         :ok <- Tracker.set_stage(issue.id, target["linear_state"], target["label"], drop_labels: [approval]) do
      Store.record_review(IssueStage.flow_scope(issue) || Store.default_team(), from["id"], verdict, actor(socket))
      if verdict == :sent_back, do: record_move(issue.id, socket.assigns.current_user, target)
      labels = issue.labels |> replace_stage_label(target["label"]) |> Enum.reject(&(String.downcase(&1) == approval))
      UsageLedger.observe_issue(%{issue | state: target["linear_state"], labels: labels})

      Orchestrator.request_refresh()
      ObservabilityPubSub.broadcast_update()
      :ok
    end
  end

  defp move_issue(socket, id, to) do
    with :ok <- authorize(socket, fn _user -> true end, :signed_out),
         {:ok, %Issue{} = issue} <- fetch_movable_issue(id),
         :ok <- authorize(socket, &Auth.can_move_issue?(&1, issue.identifier, issue.project_slug), :not_team_member),
         {:ok, target} <- allowed_move(socket, issue, to),
         approval = IssueStage.approval_label(),
         :ok <- Tracker.set_stage(issue.id, target["linear_state"], target["label"], drop_labels: [approval]) do
      record_move(issue.id, socket.assigns.current_user, target)
      labels = issue.labels |> replace_stage_label(target["label"]) |> Enum.reject(&(String.downcase(&1) == approval))
      UsageLedger.observe_issue(%{issue | state: target["linear_state"], labels: labels})

      Orchestrator.request_refresh()
      ObservabilityPubSub.broadcast_update()
      :ok
    end
  end

  # Members make the person-moved connections of their flow; admins can make
  # any connection the flow defines.
  defp allowed_move(socket, issue, to) do
    definition = IssueStage.definition(issue)
    from = IssueStage.stage(issue)

    with %{} = target <- Definition.stage(definition, to) || {:error, :unknown_target},
         %{} = transition <- Enum.find(definition["transitions"], &(&1["from"] == from and &1["to"] == to)) || {:error, :not_a_move} do
      {:ok, user} = UserAuth.refresh_user(socket)

      if transition["by"] == "human" or Auth.can_control?(user), do: {:ok, target}, else: {:error, :agent_move}
    end
  end

  # Linear labels belong to teams: a project's flow needs them in every team
  # whose issues the project holds.
  defp sync_stage_labels(scope, definition) do
    labels = definition["stages"] |> Enum.map(& &1["label"]) |> Enum.filter(&is_binary/1)

    teams =
      case scope do
        "project:" <> slug -> get_in(UsageLedger.projects(), [slug, :teams]) || []
        team -> if team == Store.default_team(), do: [], else: [team]
      end

    if labels != [], do: Enum.each(teams, &sync_team_labels(&1, labels))
    :ok
  end

  defp sync_team_labels(team, labels), do: Task.start(fn -> log_label_sync(team, Tracker.ensure_stage_labels(team, labels)) end)

  defp log_label_sync(_team, {:ok, []}), do: :ok
  defp log_label_sync(team, {:ok, created}), do: Logger.info("Created Linear labels team=#{team} labels=#{Enum.join(created, ",")}")
  defp log_label_sync(team, {:error, reason}), do: Logger.warning("Linear label sync failed team=#{team} reason=#{inspect(reason)}")

  defp actor(socket), do: socket.assigns.current_user.username || "local"

  # Moves are made with Symphony's Linear key, so leave a note saying who did it.
  defp record_move(_issue_id, %Auth.User{local: true}, _target), do: :ok

  defp record_move(issue_id, user, target) do
    where = if target["label"], do: "#{target["name"]} (#{target["linear_state"]} · #{IssueStage.label_prefix()}/#{target["label"]})", else: "#{target["name"]} (#{target["linear_state"]})"

    body = "**Symphony:** #{escape_markdown(user.name)} (@#{escape_markdown(user.username)}) moved this to **#{escape_markdown(where)}** from the dashboard."

    case Tracker.create_comment(issue_id, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Move comment failed issue_id=#{issue_id} reason=#{inspect(reason)}")
    end
  end

  # Linear display names are user-controlled; keep them from adding links or formatting.
  defp escape_markdown(text), do: String.replace(to_string(text), ~r/([\\`*_{}\[\]()#+\-.!|<>~])/, "\\\\\\1")

  # Server enforces every permission; the client only hides what the user can't use.
  # Checks against a freshly resolved user, so a disabled account or a lost
  # Linear role can't keep acting from a page opened earlier.
  defp authorize(socket, allowed?, denied_reason) when is_function(allowed?, 1) do
    with true <- FactoryPresenter.controls_enabled?(Config.settings!()) || {:error, :controls_disabled},
         {:ok, user} <- UserAuth.refresh_user(socket) do
      if allowed?.(user), do: :ok, else: {:error, denied_reason}
    end
  end

  # Per-user view of the factory payload: what this person may change, and
  # team names from their Linear memberships.
  defp factory_json(factory, user) do
    enabled? = FactoryPresenter.controls_enabled?(Config.settings!())
    names = Map.new(user.teams, &{&1.key, &1.name})
    editable = Map.new(factory.teams, &{&1.key, enabled? and Auth.can_edit_factory?(user, &1.key)})

    factory
    |> Map.update!(:teams, fn teams -> Enum.map(teams, &Map.put(&1, :name, &1.name || names[&1.key])) end)
    |> Map.put(:controls_enabled, enabled? and Auth.can_control?(user))
    |> Map.put(:movable_teams, if(enabled?, do: Auth.movable_teams(user), else: []))
    |> Map.put(:movable_projects, if(enabled?, do: Auth.movable_projects(user), else: []))
    |> Map.put(:can_edit, editable)
    |> Map.put(:can_control, editable)
    |> Jason.encode!()
  end

  defp fetch_movable_issue(id) do
    case Tracker.fetch_issue_states_by_ids([id]) do
      {:ok, [%Issue{} = issue | _]} ->
        if in_configured_project?(issue), do: {:ok, issue}, else: {:error, :issue_not_found}

      {:ok, []} ->
        {:error, :issue_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Symphony may only move issues from the Linear projects it is configured for.
  defp in_configured_project?(%Issue{project_slug: slug}) do
    case Config.linear_project_routes() |> Enum.map(& &1.slug) do
      [] -> true
      slugs -> slug in slugs
    end
  end

  defp replace_stage_label(labels, stage) do
    stage = stage && String.downcase(stage)
    prefix = IssueStage.label_prefix() <> "/"
    kept = Enum.reject(labels, &String.starts_with?(String.downcase(&1), prefix))
    if stage, do: kept ++ [prefix <> stage], else: kept
  end

  defp describe_error(:controls_disabled), do: "This dashboard is read-only (server.controls: false)."
  defp describe_error(:not_admin), do: "Only Linear admins can do that."
  defp describe_error(:not_team_editor), do: "Only this team's members and Linear admins can change its flow."
  defp describe_error(:unknown_target), do: "That stage isn't in this team's flow."
  defp describe_error(:not_a_move), do: "That move isn't a connection in this team's flow."
  defp describe_error(:agent_move), do: "Agents make that move. Only admins can force it."
  defp describe_error(:not_awaiting_approval), do: "That issue isn't waiting for approval any more."
  defp describe_error(:unknown_origin), do: "Symphony doesn't know which stage that came from. Move it from its stage instead."
  defp describe_error(:invalid_team), do: "That isn't a valid team."
  defp describe_error(:not_team_member), do: "You can only move issues from teams you belong to in Linear."
  defp describe_error({:stage_label_not_found, label}), do: "Create the Linear label #{label} first."
  defp describe_error(:signed_out), do: "Your session ended. Sign in again."
  defp describe_error(:pending), do: "Your session ended. Sign in again."
  defp describe_error(:issue_not_found), do: "That issue isn't in a project this Symphony manages."
  defp describe_error(:state_not_found), do: "That Linear state does not exist for this team."
  defp describe_error(reason), do: inspect(reason)

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <.topbar instance_name={@instance_name} current_user={@current_user} teams={@team_choices} team={@team_filter}>
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
          data-json={factory_json(@payload.factory, @current_user)}
          hidden
        >
        </div>

        <section id="factory" class="factory" aria-label="Agent factory">
          <div id="fx-stats" class="fx-stats" data-fx="stats" phx-update="ignore"></div>

          <div class="factory-main">
            <section class="panel flow-panel">
              <div class="panel-head">
                <h2 class="panel-title">Flow</h2>
                <p class="panel-hint">Click a stage to manage it or move its issues. Solid lines are agent moves, dotted lines are person moves.</p>
              </div>
              <div id="fx-diagram" data-fx="diagram" phx-update="ignore"></div>
            </section>

            <aside class="panel attention-panel" aria-label="Needs you">
              <div id="fx-drawer" class="fx-drawer-slot" data-fx="drawer" phx-update="ignore"></div>
              <div class="panel-head">
                <h2 class="panel-title">Needs you</h2>
                <span class={["count-pill", attention_count(@payload, @current_user) > 0 && "count-pill-hot"]}>
                  <%= attention_count(@payload, @current_user) %>
                </span>
              </div>

              <div :if={pending_accounts(@current_user) != []} class="attention-group">
                <h3 class="attention-title">
                  <span class="attention-icon attention-icon-review" aria-hidden="true">+</span>
                  Pending accounts
                  <span class="attention-count numeric"><%= length(pending_accounts(@current_user)) %></span>
                </h3>
                <p class="attention-more">Only approve people you expect. <a href="/admin/users">Review in Users</a></p>
                <div :for={account <- pending_accounts(@current_user)} class="attention-item account-request">
                  <span class="attention-id"><%= account.username %></span>
                  <span class="attention-text" title={"#{account.email} · requested from #{account[:requested_from] || "unknown"}"}>
                    <%= account.email %>
                  </span>
                  <span class="account-request-actions">
                    <button type="button" class="fx-action is-primary" phx-click="approve_account" phx-value-id={account.id}>
                      Approve
                    </button>
                    <button
                      type="button"
                      class="fx-action"
                      phx-click="reject_account"
                      phx-value-id={account.id}
                      data-confirm={"Reject #{account.username}'s request?"}
                    >
                      Reject
                    </button>
                  </span>
                </div>
              </div>

              <p :if={@approval_error} class="attention-more" role="alert"><%= @approval_error %></p>

              <%= if attention_count(@payload, @current_user) == 0 do %>
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
                      <%= if Auth.can_move_issue?(@current_user, item.id, item.project) do %>
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
                        <a class="issue-id" href={safe_url(entry.issue_url) || "/api/v1/#{entry.issue_identifier}"}>
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

  # The team picker offers the teams this person can see; an unknown or
  # hidden team in the URL falls back to all teams.
  defp assign_payload(socket) do
    user = socket.assigns[:current_user]
    teams = if user, do: Enum.map(user.teams, & &1.key), else: []

    visible =
      orchestrator()
      |> Presenter.state_payload(snapshot_timeout_ms(), teams: teams)
      |> Visibility.filter_payload(user)

    choices = team_choices(visible, user)
    team = if Enum.any?(choices, &(&1.key == socket.assigns.team_filter)), do: socket.assigns.team_filter

    socket
    |> assign(:team_choices, choices)
    |> assign(:team_filter, team)
    |> assign(:payload, Visibility.scope_to_team(visible, team))
  end

  defp team_choices(%{factory: %{teams: entries}}, user) do
    names = if user, do: Map.new(user.teams, &{&1.key, &1.name}), else: %{}

    entries
    |> Enum.filter(&(&1[:kind] == "team"))
    |> Enum.map(&%{key: &1.key, name: &1.name || names[&1.key]})
  end

  defp team_choices(_payload, _user), do: []

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  # ------------------------------------------------------------- needs you

  defp attention_groups(payload, now) do
    [
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

  defp attention_count(payload, user) do
    payload
    |> attention_groups(DateTime.utc_now())
    |> Enum.reduce(length(pending_accounts(user)) + length(approvals(payload, DateTime.utc_now())), &(length(&1.items) + &2))
  end

  defp pending_accounts(user) do
    if Auth.mode() == :accounts and Auth.can_control?(user), do: Users.list("pending"), else: []
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
    from = Definition.stage(definition, issue[:from])

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

  defp row_runtime(%{status: :retrying} = entry, _now) do
    "retry #{Map.get(entry, :attempt) || 0}"
  end

  defp row_runtime(entry, now) do
    format_runtime_and_turns(Map.get(entry, :started_at), Map.get(entry, :turn_count), now)
  end

  defp stage_of(%{status: :retrying}), do: "retrying"

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
