defmodule SymphonyElixirWeb.AuthController do
  @moduledoc """
  Username/password sign-in and sign-up. Sign-up is limited to emails of active
  Linear workspace members; after the first (bootstrap admin) account, new
  accounts wait for an admin to approve them.
  """

  use Phoenix.Controller, formats: [:html]
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Plug.CSRFProtection
  alias SymphonyElixir.{Auth, Config, Users}
  alias SymphonyElixirWeb.{ObservabilityPubSub, UserAuth}

  @errors %{
    invalid_credentials: "That username or password isn't right.",
    locked: "Too many attempts. Try again in 15 minutes.",
    pending: "Your account is waiting for an admin to approve it.",
    disabled: "This account has been disabled.",
    inactive_user: "That Linear account is deactivated.",
    not_in_workspace: "That email isn't a member of this Linear workspace. Use the email you sign in to Linear with.",
    linear_unavailable: "Couldn't reach Linear to check your email. Try again in a moment.",
    invalid_username: "Usernames are 3–32 characters: letters, numbers, dots, dashes, underscores.",
    invalid_email: "Enter a valid email address.",
    password_too_short: "Use at least 12 characters for your password.",
    password_mismatch: "The passwords don't match.",
    username_taken: "That username is taken.",
    email_taken: "An account with that email already exists."
  }

  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(conn, _params) do
    cond do
      Auth.mode() == :local or conn.assigns[:current_user] -> redirect(conn, to: "/")
      not Users.any?() -> redirect(conn, to: "/signup")
      true -> render_page(conn, :login, %{})
    end
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"login" => login, "password" => password}) do
    case Auth.sign_in(login, password) do
      {:ok, user} ->
        conn
        |> UserAuth.sign_in(user)
        |> redirect(to: "/")

      {:error, reason} ->
        conn
        |> put_status(401)
        |> render_page(:login, %{error: error(reason), login: login})
    end
  end

  def create(conn, _params), do: conn |> put_status(400) |> render_page(:login, %{error: error(:invalid_credentials)})

  @spec signup(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def signup(conn, _params) do
    if Auth.mode() == :local or conn.assigns[:current_user] do
      redirect(conn, to: "/")
    else
      render_page(conn, :signup, %{first?: not Users.any?()})
    end
  end

  @spec register(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def register(conn, params) do
    case Users.register(params, &Auth.check_linear_member/1) do
      {:ok, %{status: "active"} = account} ->
        {:ok, user} = Auth.user_for_account(account)

        conn
        |> UserAuth.sign_in(user)
        |> redirect(to: "/")

      {:ok, %{status: "pending"}} ->
        # Admins see the request in their Needs-you rail.
        ObservabilityPubSub.broadcast_update()
        render_page(conn, :pending, %{})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> render_page(:signup, %{
          error: error(reason),
          first?: not Users.any?(),
          username: params["username"],
          email: params["email"]
        })
    end
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> UserAuth.sign_out()
    |> redirect(to: if(Auth.mode() == :local, do: "/", else: "/login"))
  end

  defp error(reason), do: Map.get(@errors, reason, "Something went wrong. Try again.")

  defp render_page(conn, page, extra) do
    assigns =
      Map.merge(
        %{
          page: page,
          error: nil,
          login: nil,
          username: nil,
          email: nil,
          first?: false,
          csrf_token: CSRFProtection.get_csrf_token(),
          instance: Config.instance_name() || "Symphony"
        },
        extra
      )

    html(conn, assigns |> auth_page() |> Safe.to_iodata())
  end

  defp auth_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{page_title(@page)} · {@instance}</title>
        <link rel="stylesheet" href="/dashboard.css" />
      </head>
      <body>
        <main class="login-shell">
          <div class="login-card">
            <svg class="brand-mark login-mark" viewBox="0 0 32 32" aria-hidden="true">
              <path d="M6 22 L13 10 L19 18 L26 8" />
              <circle cx="6" cy="22" r="2.6" />
              <circle cx="13" cy="10" r="2.6" />
              <circle cx="19" cy="18" r="2.6" />
              <circle cx="26" cy="8" r="2.6" />
            </svg>

            <%= case @page do %>
              <% :login -> %>
                <h1 class="login-title">Sign in to {@instance}</h1>
                <form class="login-form" method="post" action="/login">
                  <input type="hidden" name="_csrf_token" value={@csrf_token} />
                  <label class="login-label" for="login">Username or email</label>
                  <input id="login" class="login-input" name="login" value={@login} autocomplete="username" autofocus required />
                  <label class="login-label" for="password">Password</label>
                  <input id="password" class="login-input" type="password" name="password" autocomplete="current-password" required />
                  <p :if={@error} class="login-error" role="alert">{@error}</p>
                  <button class="login-button" type="submit">Sign in</button>
                </form>
                <p class="login-help">New here? <a href="/signup">Create an account</a> with your Linear email.</p>
              <% :signup -> %>
                <h1 class="login-title">{if @first?, do: "Set up #{@instance}", else: "Create your account"}</h1>
                <p class="login-copy">
                  <%= if @first? do %>
                    You're the first person here, so this account will be the admin. Use the email you sign in to Linear with.
                  <% else %>
                    Use the email you sign in to Linear with. Your teams and permissions come from Linear. An admin approves new accounts.
                  <% end %>
                </p>
                <form class="login-form" method="post" action="/signup">
                  <input type="hidden" name="_csrf_token" value={@csrf_token} />
                  <label class="login-label" for="username">Username</label>
                  <input id="username" class="login-input" name="username" value={@username} autocomplete="username" autofocus required />
                  <label class="login-label" for="email">Linear email</label>
                  <input id="email" class="login-input" type="email" name="email" value={@email} autocomplete="email" required />
                  <label class="login-label" for="password">Password</label>
                  <input
                    id="password"
                    class="login-input"
                    type="password"
                    name="password"
                    autocomplete="new-password"
                    minlength="12"
                    required
                  />
                  <label class="login-label" for="password_confirmation">Confirm password</label>
                  <input
                    id="password_confirmation"
                    class="login-input"
                    type="password"
                    name="password_confirmation"
                    autocomplete="new-password"
                    minlength="12"
                    required
                  />
                  <p class="login-help">At least 12 characters.</p>
                  <p :if={@error} class="login-error" role="alert">{@error}</p>
                  <button class="login-button" type="submit">{if @first?, do: "Create admin account", else: "Request access"}</button>
                </form>
                <p :if={!@first?} class="login-help">Already have an account? <a href="/login">Sign in</a>.</p>
              <% :pending -> %>
                <h1 class="login-title">Request sent</h1>
                <p class="login-copy">
                  An admin needs to approve your account. Once they do, <a href="/login">sign in</a>
                  with your username and password.
                </p>
            <% end %>
          </div>
        </main>
      </body>
    </html>
    """
  end

  defp page_title(:login), do: "Sign in"
  defp page_title(:signup), do: "Create account"
  defp page_title(:pending), do: "Request sent"
end
