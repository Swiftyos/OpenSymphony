defmodule SymphonyElixirWeb.UserAuth do
  @moduledoc """
  Plugs and LiveView hooks that put the signed-in user on every request.

  In `:local` auth mode everyone is the local operator. In `:accounts` mode the
  encrypted session cookie carries the account id; API clients such as metrics
  scrapers may instead send `Authorization: Bearer <server.api_token>`.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias SymphonyElixir.{Auth, Config, Users}

  @session_key "user_id"
  @version_key "session_version"

  @spec fetch_current_user(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def fetch_current_user(conn, _opts) do
    case Auth.mode() do
      :local ->
        assign(conn, :current_user, Auth.local_user())

      :accounts ->
        case Auth.user_for_id(get_session(conn, @session_key), get_session(conn, @version_key) || 0) do
          {:ok, user} -> assign(conn, :current_user, user)
          {:error, _reason} -> assign(conn, :current_user, nil)
        end
    end
  end

  @spec require_user(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def require_user(%{assigns: %{current_user: %Auth.User{}}} = conn, _opts), do: conn

  def require_user(conn, _opts) do
    conn
    |> redirect(to: "/login")
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
      |> json(%{error: %{code: "unauthorized", message: "Sign in at /login or send server.api_token as a bearer token."}})
      |> halt()
    end
  end

  @spec sign_in(Plug.Conn.t(), Auth.User.t()) :: Plug.Conn.t()
  def sign_in(conn, %Auth.User{id: id}) do
    version =
      case Users.get(id) do
        %{session_version: version} -> version
        _ -> 0
      end

    conn
    |> configure_session(renew: true)
    |> put_session(@session_key, id)
    |> put_session(@version_key, version)
    # Lets disconnect_sessions/1 drop this person's open LiveView sockets.
    |> put_session(:live_socket_id, socket_topic(id))
  end

  @doc """
  Disconnects every open dashboard tab for an account. They reconnect through
  `on_mount`, which re-checks the account (disabled, new password, ...).
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
      :accounts -> Auth.user_for_id(socket.assigns.current_user.id, socket.assigns[:session_version] || 0)
    end
  end

  defp socket_topic(account_id), do: "users_socket:" <> account_id

  @spec sign_out(Plug.Conn.t()) :: Plug.Conn.t()
  def sign_out(conn), do: configure_session(conn, drop: true)

  @doc """
  LiveView mount hook: assigns `:current_user` or redirects to the sign-in page.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:require_user, _params, session, socket) do
    case Auth.mode() do
      :local ->
        {:cont, Phoenix.Component.assign(socket, :current_user, Auth.local_user())}

      :accounts ->
        case Auth.user_for_id(session[@session_key], session[@version_key] || 0) do
          {:ok, user} -> {:cont, Phoenix.Component.assign(socket, current_user: user, session_version: session[@version_key] || 0)}
          {:error, _reason} -> {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
        end
    end
  end

  @doc """
  LiveView mount hook for admin-only pages.
  """
  @spec require_admin(Phoenix.LiveView.Socket.t()) :: {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def require_admin(socket) do
    if Auth.can_control?(socket.assigns[:current_user]),
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
