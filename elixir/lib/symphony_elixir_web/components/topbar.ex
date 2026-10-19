defmodule SymphonyElixirWeb.Topbar do
  @moduledoc """
  The shared top bar: brand, page-specific status items, and the user menu.
  """

  use Phoenix.Component

  alias SymphonyElixir.Auth

  attr(:instance_name, :string, default: nil)
  attr(:current_user, :any, required: true)
  slot(:inner_block)

  @spec topbar(map()) :: Phoenix.LiveView.Rendered.t()
  def topbar(assigns) do
    ~H"""
    <header class="topbar">
      <a class="brand" href="/">
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
      </a>

      <div class="topbar-meta">
        {render_slot(@inner_block)}
        <details :if={!@current_user.local} class="user-menu">
          <summary class="user-chip" title={user_title(@current_user)}>
            <img :if={@current_user.avatar_url} class="user-avatar" src={@current_user.avatar_url} alt="" />
            <span :if={!@current_user.avatar_url} class="user-avatar user-avatar-initial">
              {String.first(@current_user.name || "?")}
            </span>
            <span class="user-name">{@current_user.name}</span>
          </summary>
          <div class="user-menu-panel">
            <p class="user-menu-who">
              <strong>@{@current_user.username}</strong>
              <span>{role(@current_user)}</span>
            </p>
            <a href="/account">Account &amp; password</a>
            <a :if={Auth.can_control?(@current_user)} href="/admin/users">Users</a>
            <%!-- POST-only so other sites can't sign people out; the token comes from the page's meta tag. --%>
            <form
              method="post"
              action="/logout"
              onsubmit="this._csrf_token.value = document.querySelector('meta[name=csrf-token]').content"
            >
              <input type="hidden" name="_csrf_token" value="" />
              <button type="submit" class="user-menu-signout">Sign out</button>
            </form>
          </div>
        </details>
      </div>
    </header>
    """
  end

  defp role(user) do
    teams = Enum.map_join(user.teams, ", ", & &1.key)

    base =
      cond do
        user.admin -> "Admin"
        user.guest -> "Guest (read-only)"
        true -> "Member"
      end

    if teams == "", do: base, else: "#{base} · #{teams}"
  end

  defp user_title(user), do: "#{user.email || user.name} · #{role(user)}"
end
