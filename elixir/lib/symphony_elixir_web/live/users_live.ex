defmodule SymphonyElixirWeb.UsersLive do
  @moduledoc """
  Admin page for Symphony accounts: approve or reject sign-ups, disable or
  re-enable people, and hand out one-time password reset links.

  Roles are not edited here: they come from Linear (admin flag, team
  memberships) for each account's email.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}
  import SymphonyElixirWeb.Topbar

  alias SymphonyElixir.{Auth, Config, Users}
  alias SymphonyElixirWeb.{ObservabilityPubSub, UserAuth}

  @impl true
  def mount(_params, _session, socket) do
    case UserAuth.require_admin(socket) do
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

    assign(socket, :groups, [
      {"Waiting for approval", "pending", Enum.filter(accounts, &(&1.status == "pending"))},
      {"Active", "active", Enum.filter(accounts, &(&1.status == "active"))},
      {"Disabled", "disabled", Enum.filter(accounts, &(&1.status == "disabled"))}
    ])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <.topbar instance_name={@instance_name} current_user={@current_user}>
        <a class="meta-link" href="/">Dashboard</a>
      </.topbar>

      <section class="panel">
        <div class="panel-head">
          <h2 class="panel-title">Users</h2>
          <p class="panel-hint">Roles and teams come from Linear for each account's email. Approve people here.</p>
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
                <td class="num numeric muted">{account.last_sign_in_at || "never"}</td>
                <td class="num">
                  <div class="row-actions">
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
    teams = Enum.map_join(linear.teams, ", ", & &1.key)

    base =
      cond do
        linear.admin -> "Linear admin"
        linear.guest -> "Guest"
        true -> "Member"
      end

    if teams == "", do: base, else: "#{base} · #{teams}"
  end

  defp problem_label(:not_in_workspace), do: "Not in Linear workspace"
  defp problem_label(:inactive_user), do: "Deactivated in Linear"
  defp problem_label(reason), do: to_string(reason)
end
