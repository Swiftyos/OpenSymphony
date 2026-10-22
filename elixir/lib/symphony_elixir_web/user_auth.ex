defmodule SymphonyElixirWeb.UserAuth do
  @moduledoc """
  Plugs and LiveView hooks that put the signed-in user on every request.

  In `:local` auth mode everyone is the local operator. In `:iap` mode Google
  Identity-Aware Proxy signs people in: every request must carry IAP's signed
  header (`SymphonyElixir.Iap`), and the verified email picks the account
  (`SymphonyElixir.Auth.user_for_email/1`). Symphony has no sign-in or sign-out
  of its own. API clients such as metrics scrapers may instead send
  `Authorization: Bearer <server.api_token>`.

  The session cookie only carries the verified account to LiveView sockets, and
  only for an hour after the page load IAP checked; after that a reconnecting
  socket reloads the page, which goes through IAP again.

  Without `server.iap_audiences` nothing is accepted, except
  `SYMPHONY_DEV_USER` for running the dashboard on a laptop
  (`SymphonyElixir.Auth.dev_user/0`).
  """

  import Plug.Conn
  import Phoenix.Controller

  alias SymphonyElixir.{Auth, Config, Iap, Users}

  @iap_header "x-goog-iap-jwt-assertion"
  @session_key "user_id"
  @version_key "session_version"
  @verified_key "iap_verified_at"
  @session_max_age_s 3_600

  @spec fetch_current_user(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def fetch_current_user(conn, _opts) do
    case Auth.mode() do
      :local ->
        assign(conn, :current_user, Auth.local_user())

      :iap ->
        with {:ok, email} <- verified_email(conn),
             {:ok, user} <- Auth.user_for_email(email) do
          conn
          |> assign(:current_user, user)
          |> put_identity(user)
        else
          {:error, reason} ->
            conn
            |> assign(:current_user, nil)
            |> assign(:auth_error, reason)
            |> delete_session(@session_key)
        end
    end
  end

  defp verified_email(conn) do
    case {Auth.iap_audiences(), Auth.dev_user()} do
      {[], nil} -> {:error, :iap_not_configured}
      {[], dev_user} -> {:ok, dev_user}
      {audiences, _dev_user} -> conn |> get_req_header(@iap_header) |> List.first() |> Iap.verify(audiences) |> email()
    end
  end

  defp email({:ok, %{email: email}}), do: {:ok, email}
  defp email({:error, :missing}), do: {:error, :iap_missing}
  defp email({:error, _reason} = error), do: error

  # LiveView sockets read the account from the session.
  defp put_identity(conn, user) do
    version =
      case Users.get(user.id) do
        %{session_version: version} -> version
        _ -> 0
      end

    conn
    |> put_session(@session_key, user.id)
    |> put_session(@version_key, version)
    |> put_session(@verified_key, System.system_time(:second))
    # Lets disconnect_sessions/1 drop this person's open LiveView sockets.
    |> put_session(:live_socket_id, socket_topic(user.id))
  end

  @spec require_user(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def require_user(%{assigns: %{current_user: %Auth.User{}}} = conn, _opts), do: conn

  def require_user(conn, _opts) do
    {status, title, message} = refusal(conn.assigns[:auth_error])

    conn
    |> put_status(status)
    |> put_resp_content_type("text/html")
    |> send_resp(status, refusal_page(title, message))
    |> halt()
  end

  @spec require_api_user(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def require_api_user(%{assigns: %{current_user: %Auth.User{}}} = conn, _opts), do: conn

  def require_api_user(conn, _opts) do
    if api_token_valid?(conn) do
      conn
    else
      conn
      |> put_resp_header("www-authenticate", ~s(Bearer realm="symphony"))
      |> put_status(401)
      |> json(%{error: %{code: "unauthorized", message: "Open Symphony through its address (Google sign-in) or send server.api_token as a bearer token."}})
      |> halt()
    end
  end

  defp refusal(:disabled), do: {403, "Account disabled", "Your Symphony account has been disabled. Ask a Symphony admin."}
  defp refusal(:inactive_user), do: {403, "No access", "Your Linear account is deactivated, so Symphony is closed to you."}

  defp refusal(:not_in_workspace),
    do: {403, "No access", "Symphony uses your Linear account for permissions, and there's no Linear user with your Google email in this workspace."}

  defp refusal(:iap_not_configured),
    do: {503, "Sign-in not configured", "This Symphony has no server.iap_audiences, so it can't check Google sign-in. Ask whoever runs it."}

  defp refusal(_reason), do: {401, "Sign in through Symphony's address", "Symphony signs you in with Google at #{address()}. Open it there."}

  defp address, do: Config.settings!().server.public_url || "its public address"

  defp refusal_page(title, message) do
    escape = fn text -> text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string() end

    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{escape.(title)}</title>
        <link rel="stylesheet" href="#{SymphonyElixirWeb.StaticAssets.url("/dashboard.css")}" />
      </head>
      <body>
        <main class="login-shell">
          <div class="login-card">
            <h1 class="login-title">#{escape.(title)}</h1>
            <p class="login-copy">#{escape.(message)}</p>
          </div>
        </main>
      </body>
    </html>
    """
  end

  @doc """
  Disconnects every open dashboard tab for an account. They reconnect through
  `on_mount`, which re-checks the account (disabled, ...).
  """
  @spec disconnect_sessions(String.t()) :: :ok
  def disconnect_sessions(account_id) when is_binary(account_id) do
    SymphonyElixirWeb.Endpoint.broadcast(socket_topic(account_id), "disconnect", %{})
    :ok
  end

  @doc """
  Re-resolves the socket's user before a mutating event, so permission changes
  in Linear or Symphony apply to already-open pages too.
  """
  @spec refresh_user(Phoenix.LiveView.Socket.t()) :: {:ok, Auth.User.t()} | {:error, atom()}
  def refresh_user(socket) do
    case Auth.mode() do
      :local -> {:ok, Auth.local_user()}
      :iap -> Auth.user_for_id(socket.assigns.current_user.id, socket.assigns[:session_version] || 0)
    end
  end

  defp socket_topic(account_id), do: "users_socket:" <> account_id

  @doc """
  LiveView mount hook: assigns `:current_user`, or reloads the page so IAP
  checks the person again.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:require_user, _params, session, socket) do
    case Auth.mode() do
      :local ->
        {:cont, Phoenix.Component.assign(socket, :current_user, Auth.local_user())}

      :iap ->
        with true <- fresh?(session[@verified_key]),
             {:ok, user} <- Auth.user_for_id(session[@session_key], session[@version_key] || 0) do
          {:cont, Phoenix.Component.assign(socket, current_user: user, session_version: session[@version_key] || 0)}
        else
          _ -> {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
        end
    end
  end

  defp fresh?(verified_at) when is_integer(verified_at), do: System.system_time(:second) - verified_at < @session_max_age_s
  defp fresh?(_verified_at), do: false

  @doc """
  LiveView mount hook for the Users page: admins and team admins.
  """
  @spec require_access_manager(Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def require_access_manager(socket) do
    if Auth.can_manage_access?(socket.assigns[:current_user]),
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
  end

  defp api_token_valid?(conn) do
    configured = Config.settings!().server.api_token

    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when is_binary(configured) ->
        Plug.Crypto.secure_compare(String.trim(token), configured)

      _ ->
        false
    end
  end
end
