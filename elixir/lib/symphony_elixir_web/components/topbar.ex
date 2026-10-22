defmodule SymphonyElixirWeb.Topbar do
  @moduledoc """
  The shared top bar: brand, page links, the team and project pickers,
  page-specific status items, and the user menu (which holds the admin pages).
  """

  use Phoenix.Component

  alias SymphonyElixir.Policy
  alias SymphonyElixirWeb.Brand

  attr(:instance_name, :string, default: nil)
  attr(:current_user, :any, required: true)
  attr(:teams, :list, default: [], doc: "team picker choices (%{key, name}); none hides the picker")
  attr(:team, :string, default: nil)
  attr(:projects, :list, default: [], doc: "project picker choices (%{slug, name}), the chosen team's when one is")
  attr(:project, :string, default: nil)
  attr(:current, :string, default: "factory", doc: "the nav item for this page")
  slot(:inner_block)

  @spec topbar(map()) :: Phoenix.LiveView.Rendered.t()
  def topbar(assigns) do
    ~H"""
    <header class="topbar">
      <a class="brand" href="/">
        <img :if={logo?()} class="brand-logo" src="/branding/logo" alt="" />
        <Brand.tile :if={!logo?()} id="brand-tile" class="brand-tile" />
        <h1 class="ops-title">
          <span class="sr-only">Agent Factory</span>
          <span class="brand-name" aria-hidden="true">Agent Factory</span>
        </h1>
      </a>

      <nav class="topnav" aria-label="Pages">
        <a :for={item <- nav_items(@current_user)} href={item.href} class={["topnav-link", item.key == @current && "is-current"]}>
          {item.label}
        </a>
      </nav>

      <form :if={@teams != []} id="team-picker" class="team-picker" phx-change="pick_team" phx-hook="TeamPicker">
        <label class="team-picker-label" for="team-picker-select">Team</label>
        <select
          id="team-picker-select"
          name="team"
          class="team-picker-select dd-native"
          tabindex="-1"
          phx-hook="Dropdown"
          data-dropdown-slot="team-picker-dd"
          data-dropdown-search
        >
          <option value="all" selected={is_nil(@team)}>All teams</option>
          <option :for={t <- @teams} value={t.key} selected={t.key == @team}>
            {t.key}{if t.name, do: " · #{t.name}"}
          </option>
        </select>
        <span id="team-picker-dd" class="dd" phx-update="ignore"></span>
        <label :if={@projects != []} class="team-picker-label" for="project-picker-select">Project</label>
        <select
          :if={@projects != []}
          id="project-picker-select"
          name="project"
          class="team-picker-select dd-native"
          tabindex="-1"
          phx-hook="Dropdown"
          data-dropdown-slot="project-picker-dd"
          data-dropdown-search
        >
          <option value="all" selected={is_nil(@project)}>All projects</option>
          <option :for={p <- @projects} value={p.slug} selected={p.slug == @project}>{p.name}</option>
        </select>
        <span :if={@projects != []} id="project-picker-dd" class="dd" phx-update="ignore"></span>
      </form>

      <div class="topbar-meta">
        {render_slot(@inner_block)}
        <%!-- The browser sets `open`; the server never does, so LiveView must not
             strip it on every update, or the menu snaps shut while the
             dashboard is busy. --%>
        <details
          :if={!@current_user.local}
          id="user-menu"
          class="user-menu"
          phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
        >
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
            <a :if={mcp_enabled?()} href="/account/mcp">MCP setup</a>
            <a href="/api/v1/state">State API</a>
            <a :if={Policy.can?(@current_user, :view_metrics)} href="/metrics">Prometheus metrics</a>
            <a :if={Policy.can?(@current_user, :view_users)} href="/admin/users">Users</a>
            <%!-- Sign-in is Google IAP's; this clears its login cookie. --%>
            <a class="user-menu-signout" href="/?gcp-iap-mode=CLEAR_LOGIN_COOKIE">Sign out of Google sign-in</a>
          </div>
        </details>
      </div>
    </header>
    """
  end

  # The page links. Users is an admin page, so it lives in the user menu.
  defp nav_items(_user) do
    [
      %{key: "factory", label: "Factory", href: "/"},
      %{key: "insights", label: "Traces & metrics", href: "/insights"}
    ]
  end

  defp logo?, do: is_binary(SymphonyElixir.Config.instance_logo())

  defp mcp_enabled?, do: SymphonyElixir.Config.settings!().server.mcp.enabled == true

  defp role(user) do
    teams = Enum.map_join(user.teams, ", ", & &1.key)

    base =
      cond do
        user.admin -> "Admin"
        user.global_viewer -> "Global viewer (read-only)"
        user.guest -> "Guest (read-only)"
        true -> "Member"
      end

    if teams == "", do: base, else: "#{base} · #{teams}"
  end

  defp user_title(user), do: "#{user.email || user.name} · #{role(user)}"
end
