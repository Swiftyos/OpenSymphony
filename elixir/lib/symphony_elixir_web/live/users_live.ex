defmodule SymphonyElixirWeb.UsersLive do
  @moduledoc """
  Accounts and access. Admins approve or reject sign-ups, disable or re-enable
  people, hand out one-time password reset links, and make people admins of
  teams. Team admins (and admins) give people access to their teams and to the
  projects their teams work in.

  Linear roles and team memberships are shown but not edited here: they come
  from Linear for each account's email. Symphony's grants add to them.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}
  import SymphonyElixirWeb.Topbar

  alias SymphonyElixir.{Auth, Config, UsageLedger, Users}
  alias SymphonyElixir.Factory.Store
  alias SymphonyElixirWeb.{ObservabilityPubSub, UserAuth}

  @impl true
  def mount(_params, _session, socket) do
    case UserAuth.require_access_manager(socket) do
      {:cont, socket} ->
        if connected?(socket), do: :ok = ObservabilityPubSub.subscribe()

        {:ok,
         socket
         |> assign(instance_name: Config.instance_name(), origin: nil, reset_link: nil, flash_message: nil)
         |> load_accounts()}

      {:halt, socket} ->
        {:ok, socket}
    end
  end

  @impl true
  def handle_params(_params, uri, socket) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(uri)
    default_port? = (scheme == "http" and port == 80) or (scheme == "https" and port == 443)
    {:noreply, assign(socket, :origin, "#{scheme}://#{host}#{if default_port?, do: "", else: ":#{port}"}")}
  end

  @impl true
  def handle_info(:observability_updated, socket), do: {:noreply, load_accounts(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event(action, %{"id" => id}, socket) when action in ["approve", "reject", "disable", "enable", "reset"] do
    case UserAuth.refresh_user(socket) do
      {:ok, user} ->
        if Auth.can_control?(user),
          do: {:noreply, socket |> apply_action(action, id) |> load_accounts()},
          else: {:noreply, assign(socket, :flash_message, "Only admins can manage accounts.")}

      {:error, _reason} ->
        {:noreply, redirect(socket, to: "/login")}
    end
  end

  def handle_event("dismiss_reset", _params, socket), do: {:noreply, assign(socket, :reset_link, nil)}

  # `choice` is "access:<scope>" or "admin:<team>"; an empty choice is the
  # select's placeholder. Grants come from a form (`account`), revokes from a
  # chip's button (`id`).
  def handle_event("grant", %{"account" => id} = params, socket),
    do: handle_event("grant", params |> Map.delete("account") |> Map.put("id", id), socket)

  def handle_event(action, %{"id" => id, "choice" => choice}, socket) when action in ["grant", "revoke"] and choice != "" do
    case UserAuth.refresh_user(socket) do
      {:ok, user} ->
        socket = socket |> assign(:current_user, user) |> change_access(user, id, choice, action == "grant")
        {:noreply, load_accounts(socket)}

      {:error, _reason} ->
        {:noreply, redirect(socket, to: "/login")}
    end
  end

  def handle_event(action, _params, socket) when action in ["grant", "revoke"], do: {:noreply, socket}

  defp change_access(socket, user, id, "admin:" <> team, admin?) do
    if Auth.can_control?(user) do
      message = if admin?, do: "Now a #{team} admin.", else: "No longer a #{team} admin."
      socket |> result(Users.set_team_admin(id, team, admin?, actor(socket)), message) |> resync(id)
    else
      assign(socket, :flash_message, "Only admins can choose team admins.")
    end
  end

  defp change_access(socket, user, id, "access:" <> scope, granted?) do
    if Auth.can_grant?(user, scope) do
      outcome = Users.set_access(id, scope, granted?, actor(socket))
      socket |> result(outcome, access_message(scope, granted?)) |> resync(id)
    else
      assign(socket, :flash_message, "You can only give access to teams you administer and their projects.")
    end
  end

  defp change_access(socket, _user, _id, _choice, _granted?), do: assign(socket, :flash_message, "Pick a team or project.")

  defp access_message("project:" <> slug, true), do: "Given access to the #{slug} project."
  defp access_message("project:" <> slug, false), do: "Removed from the #{slug} project."
  defp access_message(team, true), do: "Added to #{team}."
  defp access_message(team, false), do: "Removed from #{team}."

  # Open dashboards pick up the new access when they reconnect.
  defp resync(socket, id) do
    UserAuth.disconnect_sessions(id)
    socket
  end

  defp apply_action(socket, "approve", id), do: result(socket, Users.approve(id, actor(socket)), "Approved.")
  defp apply_action(socket, "reject", id), do: result(socket, Users.reject(id), "Request rejected.")
  defp apply_action(socket, "enable", id), do: result(socket, Users.enable(id, actor(socket)), "Re-enabled.")

  defp apply_action(socket, "disable", id) do
    if id == socket.assigns.current_user.id,
      do: assign(socket, :flash_message, "You can't disable your own account."),
      else: socket |> result(Users.disable(id, actor(socket)), "Disabled and signed out.") |> tap(fn _ -> UserAuth.disconnect_sessions(id) end)
  end

  defp apply_action(socket, "reset", id) do
    case Users.create_reset_token(id) do
      {:ok, token} ->
        account = Users.get(id)
        assign(socket, reset_link: %{username: account.username, url: "#{socket.assigns.origin}/reset/#{token}"}, flash_message: nil)

      {:error, reason} ->
        assign(socket, :flash_message, "Couldn't create a reset link: #{inspect(reason)}")
    end
  end

  defp result(socket, {:ok, _account}, message), do: broadcast_and_flash(socket, message)
  defp result(socket, :ok, message), do: broadcast_and_flash(socket, message)
  defp result(socket, {:error, :cannot_disable_bootstrap}, _), do: assign(socket, :flash_message, "The first admin account can't be disabled.")
  defp result(socket, {:error, reason}, _), do: assign(socket, :flash_message, "That didn't work: #{inspect(reason)}")

  defp broadcast_and_flash(socket, message) do
    ObservabilityPubSub.broadcast_update()
    assign(socket, :flash_message, message)
  end

  defp actor(socket), do: socket.assigns.current_user.username || "local"

  defp load_accounts(socket) do
    viewer = socket.assigns.current_user
    admin? = Auth.can_control?(viewer)

    accounts =
      Users.list()
      |> Enum.map(fn account ->
        linear =
          case Auth.user_for_account(account) do
            {:ok, user} -> user
            {:error, reason} -> %{name: account.username, admin: false, guest: false, teams: [], problem: reason}
          end

        Map.put(account, :linear, linear)
      end)

    {teams, projects} = known_scopes(accounts)

    groups =
      [
        {"Waiting for approval", "pending", Enum.filter(accounts, &(&1.status == "pending"))},
        {"Active", "active", Enum.filter(accounts, &(&1.status == "active"))},
        {"Disabled", "disabled", Enum.filter(accounts, &(&1.status == "disabled"))}
      ]
      # Team admins manage access, not accounts.
      |> Enum.filter(fn {_title, status, _accounts} -> admin? or status == "active" end)

    assign(socket,
      groups: groups,
      admin?: admin?,
      team_options: if(admin?, do: teams, else: []),
      grantable: grantable(viewer, teams, projects)
    )
  end

  # Teams and projects Symphony knows of: from Linear memberships, saved
  # flows, observed work, and configured projects.
  defp known_scopes(accounts) do
    seen = UsageLedger.projects()

    teams =
      accounts
      |> Enum.flat_map(&Map.get(&1.linear, :teams, []))
      |> Enum.map(& &1.key)
      |> Kernel.++(Store.teams() -- [Store.default_team()])
      |> Kernel.++(Enum.flat_map(Map.values(seen), & &1.teams))
      |> Enum.uniq()
      |> Enum.sort()

    projects =
      Config.settings!().tracker.projects
      |> List.wrap()
      |> Enum.map(& &1.slug)
      |> Kernel.++(Map.keys(seen) ++ Store.projects())
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.map(&%{slug: &1, name: get_in(seen, [&1, :name]) || SymphonyElixir.LabelSync.project_names()[&1] || &1})
      |> Enum.sort_by(&String.downcase(&1.name))

    {teams, projects}
  end

  defp grantable(viewer, teams, projects) do
    %{
      teams: Enum.filter(teams, &Auth.can_grant?(viewer, &1)),
      projects: Enum.filter(projects, &Auth.can_grant?(viewer, "project:" <> &1.slug))
    }
  end

  defp project_name(projects, "project:" <> slug), do: Enum.find_value(projects, slug, &(&1.slug == slug && &1.name))

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <.topbar instance_name={@instance_name} current_user={@current_user} current="users">
        <a class="meta-link" href="/">Dashboard</a>
      </.topbar>

      <section class="panel">
        <div class="panel-head">
          <h2 class="panel-title">Users</h2>
          <p class="panel-hint">
            Linear roles and teams come from each account's email. Give people extra access to teams and projects here.
          </p>
        </div>

        <p :if={@flash_message} class="users-flash" role="status">{@flash_message}</p>

        <div :if={@reset_link} class="reset-link" role="status">
          <div>
            <strong>Password reset link for @{@reset_link.username}</strong>
            <p class="muted">Send this to them privately. It works once and expires in 24 hours.</p>
            <code id="reset-url">{@reset_link.url}</code>
          </div>
          <div class="reset-link-actions">
            <button
              type="button"
              class="fx-action is-primary"
              data-copy={@reset_link.url}
              onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied';"
            >
              Copy link
            </button>
            <button type="button" class="fx-action" phx-click="dismiss_reset">Done</button>
          </div>
        </div>

        <div :for={{title, status, accounts} <- @groups} :if={accounts != [] or status == "active"} class="users-group">
          <h3 class="users-group-title">{title} <span class="numeric muted">{length(accounts)}</span></h3>
          <p :if={status == "pending" and accounts != []} class="approval-warning">
            Symphony can't prove someone owns the email they signed up with, and approving gives them that person's
            Linear permissions. Only approve requests you expect, ideally after checking with the person directly.
          </p>
          <table class="data-table users-table">
            <thead>
              <tr>
                <th>User</th>
                <th>Linear</th>
                <th>Role</th>
                <th>Access</th>
                <th class="num">Last sign-in</th>
                <th class="num"></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={account <- accounts}>
                <td>
                  <div class="issue-cell">
                    <span class="issue-id">@{account.username}</span>
                    <span class="issue-project">{account.email}</span>
                    <span :if={status == "pending" and account[:requested_from]} class="issue-project">
                      requested {account.created_at} from {account.requested_from}
                    </span>
                  </div>
                </td>
                <td>
                  <span :if={!Map.get(account.linear, :problem)}>{account.linear.name}</span>
                  <span :if={Map.get(account.linear, :problem)} class="stage-chip stage-blocked">
                    {problem_label(account.linear.problem)}
                  </span>
                </td>
                <td>
                  <span class="muted">{role(account)}</span>
                </td>
                <td>
                  <div class="access-cell">
                    <span :for={team <- linear_teams(account)} class="access-chip" title="Linear team membership">{team}</span>
                    <span :for={team <- Map.get(account, :team_admin, [])} class="access-chip access-chip-admin">
                      ★ {team} admin
                      <button
                        :if={@admin?}
                        type="button"
                        class="access-remove"
                        phx-click="revoke"
                        phx-value-id={account.id}
                        phx-value-choice={"admin:" <> team}
                        aria-label={"Remove @#{account.username} as #{team} admin"}
                      >
                        ×
                      </button>
                    </span>
                    <span :for={scope <- Map.get(account, :access, [])} class="access-chip access-chip-granted" title="Given in Symphony">
                      {scope_label(scope, @grantable.projects)}
                      <button
                        :if={Auth.can_grant?(@current_user, scope)}
                        type="button"
                        class="access-remove"
                        phx-click="revoke"
                        phx-value-id={account.id}
                        phx-value-choice={"access:" <> scope}
                        aria-label={"Remove @#{account.username} from #{scope}"}
                      >
                        ×
                      </button>
                    </span>
                    <form
                      :if={status == "active" and (@grantable.teams != [] or @grantable.projects != [] or @team_options != [])}
                      id={"grant-#{account.id}"}
                      phx-change="grant"
                      class="access-add"
                    >
                      <input type="hidden" name="account" value={account.id} />
                      <select name="choice" aria-label={"Give @#{account.username} access"}>
                        <option value="">+ Add access</option>
                        <optgroup :if={@grantable.teams != []} label="Team">
                          <option :for={team <- @grantable.teams -- Map.get(account, :access, [])} value={"access:" <> team}>
                            {team}
                          </option>
                        </optgroup>
                        <optgroup :if={@grantable.projects != []} label="Project">
                          <option
                            :for={project <- @grantable.projects}
                            :if={("project:" <> project.slug) not in Map.get(account, :access, [])}
                            value={"access:project:" <> project.slug}
                          >
                            {project.name}
                          </option>
                        </optgroup>
                        <optgroup :if={@team_options != []} label="Make team admin">
                          <option :for={team <- @team_options -- Map.get(account, :team_admin, [])} value={"admin:" <> team}>
                            ★ {team} admin
                          </option>
                        </optgroup>
                      </select>
                    </form>
                  </div>
                </td>
                <td class="num numeric muted">{account.last_sign_in_at || "never"}</td>
                <td class="num">
                  <div :if={@admin?} class="row-actions">
                    <button :if={status == "pending"} type="button" class="fx-action is-primary" phx-click="approve" phx-value-id={account.id}>
                      Approve
                    </button>
                    <button
                      :if={status == "pending"}
                      type="button"
                      class="fx-action"
                      phx-click="reject"
                      phx-value-id={account.id}
                      data-confirm={"Reject @#{account.username}'s request?"}
                    >
                      Reject
                    </button>
                    <button :if={status != "pending"} type="button" class="fx-action" phx-click="reset" phx-value-id={account.id}>
                      Reset password
                    </button>
                    <button
                      :if={status == "active" and account.id != @current_user.id and !account.bootstrap_admin}
                      type="button"
                      class="fx-action"
                      phx-click="disable"
                      phx-value-id={account.id}
                      data-confirm={"Disable @#{account.username}? They'll be signed out."}
                    >
                      Disable
                    </button>
                    <button :if={status == "disabled"} type="button" class="fx-action" phx-click="enable" phx-value-id={account.id}>
                      Re-enable
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </section>
    """
  end

  defp role(%{bootstrap_admin: true}), do: "Admin (first account)"

  defp role(%{linear: linear}) do
    cond do
      linear.admin -> "Linear admin"
      linear.guest -> "Guest"
      true -> "Member"
    end
  end

  # Teams from Linear itself; granted ones show as their own chips.
  defp linear_teams(%{linear: linear} = account) do
    granted = Map.get(account, :team_admin, []) ++ Map.get(account, :access, [])
    for %{key: key} <- Map.get(linear, :teams, []), key not in granted, do: key
  end

  defp scope_label("project:" <> _slug = scope, projects), do: "◆ " <> project_name(projects, scope)
  defp scope_label(team, _projects), do: team

  defp problem_label(:not_in_workspace), do: "Not in Linear workspace"
  defp problem_label(:inactive_user), do: "Deactivated in Linear"
end
