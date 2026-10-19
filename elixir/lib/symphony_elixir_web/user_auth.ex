defmodule SymphonyElixirWeb.UserAuth do
  @moduledoc """
  Plugs and LiveView hooks that put the signed-in Linear user on every request.

  In `:local` auth mode everyone is the local operator. In `:linear` mode the
  browser session carries the user's Linear API key (encrypted cookie), and API
  clients such as metrics scrapers may send one as `Authorization: Bearer <key>`.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias SymphonyElixir.Auth

  @session_key "linear_api_key"

  @spec fetch_current_user(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def fetch_current_user(conn, _opts) do
    case Auth.mode() do
      :local ->
        assign(conn, :current_user, Auth.local_user())

      :linear ->
        key = get_session(conn, @session_key) || bearer_key(conn)

        case Auth.user_for_key(key) do
          {:ok, user} -> conn |> assign(:current_user, user) |> assign(:linear_api_key, key)
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
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="symphony"))
    |> put_status(401)
    |> json(%{error: %{code: "unauthorized", message: "Sign in at /login or send a Linear API key as a bearer token."}})
    |> halt()
  end

  @spec sign_in(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def sign_in(conn, api_key) do
    conn
    |> configure_session(renew: true)
    |> put_session(@session_key, String.trim(api_key))
  end

  @spec sign_out(Plug.Conn.t()) :: Plug.Conn.t()
  def sign_out(conn), do: configure_session(conn, drop: true)

  @doc """
  LiveView mount hook: assigns `:current_user` and the user's Linear key, or
  redirects to the sign-in page.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:require_user, _params, session, socket) do
    case Auth.mode() do
      :local ->
        {:cont, Phoenix.Component.assign(socket, current_user: Auth.local_user(), linear_api_key: nil)}

      :linear ->
        key = session[@session_key]

        case Auth.user_for_key(key) do
          {:ok, user} ->
            {:cont, Phoenix.Component.assign(socket, current_user: user, linear_api_key: key)}

          {:error, _reason} ->
            {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
        end
    end
  end

  defp bearer_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key | _] -> String.trim(key)
      _ -> nil
    end
  end
end
