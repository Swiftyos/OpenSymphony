defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router
  import SymphonyElixirWeb.UserAuth, only: [fetch_current_user: 2, require_user: 2, require_api_user: 2]

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

  # JSON API and metrics: a browser session or `Authorization: Bearer <Linear API key>`.
  pipeline :api do
    plug(:fetch_session)
    plug(:fetch_current_user)
    plug(:require_api_user)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/factory.js", StaticAssetController, :factory_js)
    get("/factory_flow.js", StaticAssetController, :factory_flow_js)
    get("/factory_assist.js", StaticAssetController, :factory_assist_js)
    get("/branding/logo", StaticAssetController, :logo)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    get("/login", AuthController, :new)
    post("/login", AuthController, :create)
    get("/signup", AuthController, :signup)
    post("/signup", AuthController, :register)
    post("/logout", AuthController, :delete)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    get("/reset/:token", AuthController, :reset)
    post("/reset/:token", AuthController, :do_reset)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:browser, :signed_in])

    get("/account", AuthController, :account)
    post("/account/password", AuthController, :update_password)

    live_session :signed_in, on_mount: {SymphonyElixirWeb.UserAuth, :require_user} do
      live("/", DashboardLive, :index)
      live("/admin/users", UsersLive, :index)
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
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
  end

  scope "/", SymphonyElixirWeb do
    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/metrics", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
