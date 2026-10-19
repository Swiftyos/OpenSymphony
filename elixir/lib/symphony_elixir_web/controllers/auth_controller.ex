defmodule SymphonyElixirWeb.AuthController do
  @moduledoc """
  Sign in with a Linear personal API key. No user database: identity, teams, and
  admin rights come from Linear.
  """

  use Phoenix.Controller, formats: [:html]
  use Phoenix.Component

  alias Plug.CSRFProtection
  alias SymphonyElixir.{Auth, Config}
  alias SymphonyElixirWeb.UserAuth

  @errors %{
    invalid_key: "Linear didn't accept that key. Check it was copied in full.",
    inactive_user: "That Linear account is deactivated.",
    wrong_organization: "That key belongs to a different Linear workspace than this Symphony.",
    linear_unavailable: "Couldn't reach Linear. Try again in a moment."
  }

  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(conn, _params) do
    if Auth.mode() == :local or conn.assigns[:current_user] do
      redirect(conn, to: "/")
    else
      render_page(conn, nil)
    end
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"api_key" => api_key}) when is_binary(api_key) do
    case Auth.sign_in(api_key) do
      {:ok, _user} ->
        conn
        |> UserAuth.sign_in(api_key)
        |> redirect(to: "/")

      {:error, reason} ->
        conn
        |> put_status(401)
        |> render_page(Map.get(@errors, reason, "Sign-in failed."))
    end
  end

  def create(conn, _params), do: conn |> put_status(400) |> render_page(Map.fetch!(@errors, :invalid_key))

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> UserAuth.sign_out()
    |> redirect(to: if(Auth.mode() == :local, do: "/", else: "/login"))
  end

  defp render_page(conn, error) do
    assigns = %{
      error: error,
      csrf_token: CSRFProtection.get_csrf_token(),
      instance: Config.instance_name()
    }

    body = assigns |> login_page() |> Phoenix.HTML.Safe.to_iodata()
    html(conn, body)
  end

  defp login_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Sign in · {@instance || "Symphony"}</title>
        <link rel="stylesheet" href="/dashboard.css" />
      </head>
      <body>
        <main class="login-shell">
          <form class="login-card" method="post" action="/login">
            <svg class="brand-mark login-mark" viewBox="0 0 32 32" aria-hidden="true">
              <path d="M6 22 L13 10 L19 18 L26 8" />
              <circle cx="6" cy="22" r="2.6" />
              <circle cx="13" cy="10" r="2.6" />
              <circle cx="19" cy="18" r="2.6" />
              <circle cx="26" cy="8" r="2.6" />
            </svg>
            <h1 class="login-title">Sign in to {@instance || "Symphony"}</h1>
            <p class="login-copy">
              Use your Linear personal API key. Your teams and permissions come from Linear, and anything you
              change here is done as you.
            </p>

            <input type="hidden" name="_csrf_token" value={@csrf_token} />
            <label class="login-label" for="api_key">Linear API key</label>
            <input
              id="api_key"
              class="login-input"
              type="password"
              name="api_key"
              placeholder="lin_api_…"
              autocomplete="off"
              autofocus
              required
            />
            <p :if={@error} class="login-error" role="alert">{@error}</p>
            <button class="login-button" type="submit">Sign in</button>

            <p class="login-help">
              Create one in Linear under
              <a href="https://linear.app/settings/account/security" target="_blank" rel="noopener">Settings → Security &amp; access → Personal API keys</a>.
              Give it read and write access to issues. The key is kept only in an encrypted cookie in this browser.
            </p>
          </form>
        </main>
      </body>
    </html>
    """
  end
end
