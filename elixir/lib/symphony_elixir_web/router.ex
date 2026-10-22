defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  import SymphonyElixirWeb.UserAuth,
    only: [fetch_current_user: 2, require_user: 2, require_api_user: 2, refuse_read_only_changes: 2]

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_user)
  end

  pipeline :signed_in do
    plug(:require_user)
  end

  # JSON API and metrics: IAP sign-in or `Authorization: Bearer <server.api_token>`.
  # Read-only people (global viewers, guests) only read.
  pipeline :api do
    plug(:fetch_session)
    plug(:fetch_current_user)
    plug(:require_api_user)
    plug(:refuse_read_only_changes)
  end

  # MCP for agents: bearer tokens only, no cookies (see McpAuth).
  pipeline :mcp do
    plug(SymphonyElixirWeb.RateLimit, :mcp)
    plug(SymphonyElixirWeb.McpAuth)
  end

  # Admin tasks run against the live controller: an MCP token (see McpAuth),
  # whose account the controller checks is an admin. The load balancer keeps
  # these paths behind IAP; they're meant for a port-forward.
  pipeline :admin_token do
    plug(SymphonyElixirWeb.RateLimit, :mcp)
    plug(SymphonyElixirWeb.McpAuth)
  end

  # Runner protocol: run tokens only, no cookies and no CSRF (see RunnerAuth).
  pipeline :runner do
    plug(SymphonyElixirWeb.RunnerAuth)
  end

  # Read-only git mirror: the same run tokens, via bearer or basic auth.
  pipeline :git_mirror do
    plug(SymphonyElixirWeb.RunnerAuth)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:mcp)

    post("/mcp", McpController, :post)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:admin_token)

    post("/admin/users/import", UsersImportController, :create)
  end

  scope "/", SymphonyElixirWeb do
    match(:get, "/mcp", McpController, :method_not_allowed)
    match(:delete, "/mcp", McpController, :method_not_allowed)
  end

  scope "/", SymphonyElixirWeb do
    get("/readyz", HealthController, :ready)
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/agent_factory_logo.css", StaticAssetController, :logo_css)

    for path <- SymphonyElixirWeb.StaticAssets.brand_paths() do
      get(path, StaticAssetController, :asset)
    end

    get("/factory.js", StaticAssetController, :factory_js)
    get("/factory_flow.js", StaticAssetController, :factory_flow_js)
    get("/branding/logo", StaticAssetController, :logo)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:browser, :signed_in])

    get("/account", AccountController, :account)
    get("/account/mcp", AccountController, :mcp)
    post("/account/mcp-token/rotate", AccountController, :rotate_mcp_token)

    live_session :signed_in, on_mount: {SymphonyElixirWeb.UserAuth, :require_user} do
      live("/", DashboardLive, :index)
      live("/admin/users", UsersLive, :index)
      live("/insights", InsightsLive, :index)
    end
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:api)

    get("/metrics", ObservabilityApiController, :metrics)
    get("/api/v1/state", ObservabilityApiController, :state)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    # Delayed restart: no new runs, then restart once running agents finish (admins or server.api_token).
    post("/api/v1/restart", ObservabilityApiController, :request_restart)
    delete("/api/v1/restart", ObservabilityApiController, :cancel_restart)
    # Must precede the :issue_identifier route so GET /api/v1/refresh stays a 405.
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/issues/:issue_identifier/messages", AgentMessagesController, :index)
    post("/api/v1/issues/:issue_identifier/messages", AgentMessagesController, :create)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
  end

  scope "/git/:run_id/:repo", SymphonyElixirWeb do
    pipe_through(:git_mirror)

    get("/info/refs", GitMirrorController, :info_refs)
    post("/git-upload-pack", GitMirrorController, :upload_pack)
    post("/git-receive-pack", GitMirrorController, :read_only)
  end

  scope "/runner/v1/runs/:run_id", SymphonyElixirWeb do
    pipe_through(:runner)

    post("/events", RunnerController, :events)
    get("/session", RunnerController, :session)
    put("/session", RunnerController, :put_session)
    delete("/session", RunnerController, :delete_session)
    post("/inbox/take", RunnerController, :inbox_take)
    get("/inbox/queued", RunnerController, :inbox_queued)
    get("/inbox/:message_id", RunnerController, :inbox_get)
    post("/inbox/:message_id/delivered", RunnerController, :inbox_delivered)
    post("/codex_turn", RunnerController, :codex_turn)
    get("/commands", RunnerController, :commands)
    post("/github-token", RunnerController, :github_token)
  end

  scope "/", SymphonyElixirWeb do
    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/metrics", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/issues/:issue_identifier/messages", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
