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
  alias SymphonyElixir.{Auth, Config, McpTokens, UsageLedger, Users}
  alias SymphonyElixir.Factory.Store
  alias SymphonyElixirWeb.{ObservabilityPubSub, RateLimit, UserAuth}

  # Every action that runs a password check is throttled per client IP.
  plug(RateLimit, :login when action in [:create, :update_password])
  plug(RateLimit, :signup when action in [:register])
  plug(RateLimit, :reset when action in [:do_reset])

  @errors %{
    invalid_credentials: "That username or password isn't right. After 5 failed tries, sign-in pauses for 15 minutes.",
    # Same text as a wrong password, so the lockout doesn't reveal which accounts exist.
    locked: "That username or password isn't right. After 5 failed tries, sign-in pauses for 15 minutes.",
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
    email_taken: "An account with that email already exists.",
    invalid_reset_token: "This reset link is invalid or has expired. Ask an admin for a new one.",
    invalid_setup_code: "That setup code isn't right. Copy it from the Symphony server log.",
    name_required: "Give the token a name, such as the agent that will use it.",
    name_too_long: "Token names are 60 characters at most.",
    invalid_name: "Token names can't contain control characters.",
    invalid_scopes: "Pick read-only or read and write access.",
    invalid_lifetime: "Pick how long the token lasts.",
    lifetime_too_long: "That's longer than this Symphony allows for tokens.",
    too_many_tokens: "You have 20 tokens already. Revoke one first.",
    invalid_resources: "Pick what the token can reach: teams or projects, or everything (admins only).",
    resource_not_allowed: "You can only give a token teams and projects you work in. Only admins can give it everything.",
    not_found: "That token doesn't exist any more."
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
      first? = not Users.any?()
      # Writes the setup code to the server log the first time it's needed.
      if first?, do: Users.setup_code()
      render_page(conn, :signup, %{first?: first?})
    end
  end

  @spec register(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def register(conn, params) do
    request = %{
      "requested_from" => conn.remote_ip |> :inet.ntoa() |> to_string(),
      "requested_user_agent" => conn |> get_req_header("user-agent") |> List.first() |> then(&(&1 && String.slice(&1, 0, 200)))
    }

    case Users.register(Map.merge(params, request), &Auth.check_linear_member/1) do
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

  @spec account(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def account(conn, _params) do
    # The signed-in pipeline guarantees a user here.
    user = conn.assigns.current_user
    if show_account?(user), do: render_page(conn, :account, %{user: user}), else: redirect(conn, to: "/")
  end

  @doc """
  Creates an MCP token for the signed-in person (or the local operator) and
  shows its secret once.
  """
  @spec create_mcp_token(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_mcp_token(conn, params) do
    if mcp_enabled?(), do: create_token(conn, conn.assigns.current_user, params), else: redirect(conn, to: "/")
  end

  @spec revoke_mcp_token(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def revoke_mcp_token(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    cond do
      not mcp_enabled?() ->
        redirect(conn, to: "/")

      McpTokens.revoke(token_owner(user), id) == :ok ->
        render_page(conn, :account, %{user: user, token_notice: "Token revoked. Agents using it are cut off now."})

      true ->
        conn |> put_status(404) |> render_page(:account, %{user: user, token_error: error(:not_found)})
    end
  end

  # The owner must be allowed every resource they give the token; Auth
  # re-checks them on every request, so later changes still apply.
  defp create_token(conn, user, params) do
    scopes = if params["access"] == "write", do: ["read", "write"], else: ["read"]
    resources = params |> Map.get("resources", []) |> List.wrap() |> Enum.filter(&is_binary/1)

    with true <- Enum.all?(resources, &Auth.token_resource_allowed?(user, &1)) || {:error, :resource_not_allowed},
         {:ok, secret, token} <- McpTokens.create(token_owner(user), params["name"] || "", scopes, parse_days(params["days"]), resources) do
      render_page(conn, :account, %{user: user, new_token: %{secret: secret, token: token}})
    else
      {:error, reason} -> conn |> put_status(422) |> render_page(:account, %{user: user, token_error: error(reason)})
    end
  end

  # What a token may be limited to: everything (admins), and the teams and
  # projects this person works in (any Symphony knows of, for admins).
  defp resource_choices(user) do
    projects =
      (Map.keys(UsageLedger.projects()) ++ Store.projects() ++ Enum.map(Config.linear_project_routes(), & &1.slug) ++ user.projects)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&("project:" <> &1))

    teams =
      (Enum.map(user.teams, & &1.key) ++ Store.teams() ++ Enum.map(UsageLedger.snapshot().flow.issues, & &1.team))
      |> Enum.filter(&(is_binary(&1) and &1 != Store.default_team()))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.filter(["*" | teams ++ projects], &Auth.token_resource_allowed?(user, &1))
  end

  defp resource_label("*"), do: "Everything (admin)"
  defp resource_label("project:" <> slug), do: "Project #{get_in(UsageLedger.projects(), [slug, :name]) || slug}"
  defp resource_label(team), do: "Team #{team}"

  # The local operator has no account, so only the token section shows.
  defp show_account?(%Auth.User{local: true}), do: mcp_enabled?()
  defp show_account?(%Auth.User{}), do: true

  defp token_owner(%Auth.User{local: true}), do: "local"
  defp token_owner(%Auth.User{id: id}), do: id

  defp mcp_enabled?, do: Config.settings!().server.mcp.enabled == true

  defp parse_days(value) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} -> days
      _ -> nil
    end
  end

  defp parse_days(_value), do: nil

  defp lifetime_choices do
    max = McpTokens.max_days()
    choices = Enum.filter([7, 30, 90, 180, 365], &(&1 <= max))
    if max in choices, do: choices, else: choices ++ [max]
  end

  defp mcp_url(conn) do
    settings = Config.settings!()

    base =
      cond do
        is_binary(settings.server.mcp.host) -> "https://" <> settings.server.mcp.host
        is_binary(settings.server.public_url) -> String.trim_trailing(settings.server.public_url, "/")
        true -> "#{conn.scheme}://#{conn.host}:#{conn.port}"
      end

    base <> "/mcp"
  end

  @spec update_password(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_password(conn, params) do
    with %Auth.User{local: false} = user <- conn.assigns[:current_user],
         {:ok, _account} <-
           Users.change_password(user.id, params["current_password"] || "", params["password"] || "", params["password_confirmation"] || "") do
      # The version bump signed out every session, including this one; start a fresh one.
      UserAuth.disconnect_sessions(user.id)

      conn
      |> UserAuth.sign_in(user)
      |> render_page(:account, %{user: user, notice: "Password changed. Other sessions were signed out."})
    else
      {:error, reason} ->
        conn |> put_status(422) |> render_page(:account, %{user: conn.assigns.current_user, error: error(reason)})

      _ ->
        redirect(conn, to: "/")
    end
  end

  @spec reset(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reset(conn, %{"token" => token}) do
    case Users.reset_account_for_token(token) do
      %{username: username} -> render_page(conn, :reset, %{token: token, username: username})
      nil -> conn |> put_status(404) |> render_page(:message, %{title: "Link expired", error: error(:invalid_reset_token)})
    end
  end

  @spec do_reset(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def do_reset(conn, %{"token" => token} = params) do
    case Users.reset_password(token, params["password"] || "", params["password_confirmation"] || "") do
      {:ok, account} ->
        UserAuth.disconnect_sessions(account.id)
        render_page(conn, :message, %{title: "Password set", notice: "Your password was updated. You can sign in now."})

      {:error, :invalid_reset_token} ->
        conn |> put_status(404) |> render_page(:message, %{title: "Link expired", error: error(:invalid_reset_token)})

      {:error, reason} ->
        username = (Users.reset_account_for_token(token) || %{})[:username]
        conn |> put_status(422) |> render_page(:reset, %{token: token, username: username, error: error(reason)})
    end
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
          notice: nil,
          user: nil,
          token: nil,
          title: nil,
          new_token: nil,
          token_error: nil,
          token_notice: nil,
          mcp?: mcp_enabled?(),
          mcp_url: mcp_url(conn),
          tokens: if(page == :account, do: tokens_for(extra.user), else: []),
          lifetimes: if(mcp_enabled?(), do: lifetime_choices(), else: []),
          resource_choices: if(page == :account and mcp_enabled?(), do: resource_choices(extra.user), else: []),
          csrf_token: CSRFProtection.get_csrf_token(),
          instance: Config.instance_name() || "Symphony"
        },
        extra
      )

    html(conn, assigns |> auth_page() |> Safe.to_iodata())
  end

  defp tokens_for(%Auth.User{} = user), do: if(mcp_enabled?(), do: McpTokens.list(token_owner(user)), else: [])

  defp auth_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{page_title(@page)} · {@instance}</title>
        <link rel="stylesheet" href={SymphonyElixirWeb.StaticAssets.url("/dashboard.css")} />
      </head>
      <body>
        <main class="login-shell">
          <div class="login-card">
            <img :if={is_binary(SymphonyElixir.Config.instance_logo())} class="brand-logo login-logo" src="/branding/logo" alt="" />
            <svg :if={!is_binary(SymphonyElixir.Config.instance_logo())} class="brand-mark login-mark" viewBox="0 0 32 32" aria-hidden="true">
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
                  <%= if @first? do %>
                    <label class="login-label" for="setup_code">Setup code</label>
                    <input
                      id="setup_code"
                      class="login-input"
                      name="setup_code"
                      placeholder="XXXX-XXXX"
                      autocomplete="off"
                      autofocus
                      required
                    />
                    <p class="login-help">Printed in the Symphony server log when no accounts exist yet.</p>
                  <% end %>
                  <label class="login-label" for="username">Username</label>
                  <input id="username" class="login-input" name="username" value={@username} autocomplete="username" required />
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
              <% :account -> %>
                <h1 class="login-title">{if @user.local, do: "Agent access", else: "Your account"}</h1>
                <p :if={!@user.local} class="login-copy">
                  Signed in as <strong>@{@user.username}</strong> ({@user.email}). Teams and permissions come from Linear.
                </p>
                <form :if={!@user.local} class="login-form" method="post" action="/account/password">
                  <input type="hidden" name="_csrf_token" value={@csrf_token} />
                  <label class="login-label" for="current_password">Current password</label>
                  <input id="current_password" class="login-input" type="password" name="current_password" autocomplete="current-password" required />
                  <label class="login-label" for="password">New password</label>
                  <input id="password" class="login-input" type="password" name="password" autocomplete="new-password" minlength="12" required />
                  <label class="login-label" for="password_confirmation">Confirm new password</label>
                  <input
                    id="password_confirmation"
                    class="login-input"
                    type="password"
                    name="password_confirmation"
                    autocomplete="new-password"
                    minlength="12"
                    required
                  />
                  <p :if={@notice} class="login-notice" role="status">{@notice}</p>
                  <p :if={@error} class="login-error" role="alert">{@error}</p>
                  <button class="login-button" type="submit">Change password</button>
                </form>
                <section :if={@mcp?} class="login-form mcp-tokens" aria-labelledby="mcp-tokens-title">
                  <h2 id="mcp-tokens-title" class="login-label">MCP tokens for agents</h2>
                  <p class="login-help">
                    Agents use these to watch and steer Symphony at <code>{@mcp_url}</code>. A token can do what you can do, never more,
                    and stops working if your account is disabled.
                  </p>
                  <div :if={@new_token} class="login-notice" role="status">
                    <p>Copy this token now. It won't be shown again.</p>
                    <input class="login-input" readonly value={@new_token.secret} onclick="this.select()" aria-label="New token" />
                    <p class="login-help">For Claude Code:</p>
                    <pre class="mcp-snippet">claude mcp add --transport http symphony {@mcp_url} --header "Authorization: Bearer {@new_token.secret}"</pre>
                  </div>
                  <p :if={@token_notice} class="login-notice" role="status">{@token_notice}</p>
                  <p :if={@token_error} class="login-error" role="alert">{@token_error}</p>
                  <ul :if={@tokens != []} class="mcp-token-list">
                    <li :for={token <- @tokens}>
                      <strong>{token.name}</strong>
                      · {Enum.join(token.scopes, " + ")} on {Enum.map_join(token.resources, ", ", &resource_label/1)}
                      · <code>{token.hint}</code>
                      · expires {String.slice(token.expires_at || "", 0, 10)}
                      · {if token.last_used_at, do: "last used #{String.slice(token.last_used_at, 0, 10)}", else: "never used"}
                      <form method="post" action={"/account/mcp-tokens/#{token.id}/revoke"} style="display:inline">
                        <input type="hidden" name="_csrf_token" value={@csrf_token} />
                        <button class="login-link-button" type="submit">Revoke</button>
                      </form>
                    </li>
                  </ul>
                  <form class="login-form" method="post" action="/account/mcp-tokens">
                    <input type="hidden" name="_csrf_token" value={@csrf_token} />
                    <label class="login-label" for="token_name">Name</label>
                    <input id="token_name" class="login-input" name="name" maxlength="60" placeholder="e.g. ops agent" required />
                    <label class="login-label" for="token_access">Access</label>
                    <select id="token_access" class="login-input" name="access">
                      <option value="read">Read only: status, flows, issues, transcripts</option>
                      <option value="write">Read and write: also edit flows, move issues, message agents</option>
                    </select>
                    <fieldset class="mcp-resources">
                      <legend class="login-label">Can reach</legend>
                      <label :for={resource <- @resource_choices} class="login-help">
                        <input type="checkbox" name="resources[]" value={resource} /> {resource_label(resource)}
                      </label>
                      <p :if={@resource_choices == []} class="login-help">You aren't in any Linear team yet, so there's nothing a token could reach.</p>
                    </fieldset>
                    <label class="login-label" for="token_days">Expires after</label>
                    <select id="token_days" class="login-input" name="days">
                      <option :for={days <- @lifetimes} value={days} selected={days == 30}>{days} days</option>
                    </select>
                    <button class="login-button" type="submit">Create token</button>
                  </form>
                </section>
                <p class="login-help"><a href="/">Back to the dashboard</a></p>
              <% :reset -> %>
                <h1 class="login-title">Set a new password</h1>
                <p :if={@username} class="login-copy">For <strong>@{@username}</strong>.</p>
                <form class="login-form" method="post" action={"/reset/#{@token}"}>
                  <input type="hidden" name="_csrf_token" value={@csrf_token} />
                  <label class="login-label" for="password">New password</label>
                  <input id="password" class="login-input" type="password" name="password" autocomplete="new-password" minlength="12" autofocus required />
                  <label class="login-label" for="password_confirmation">Confirm new password</label>
                  <input
                    id="password_confirmation"
                    class="login-input"
                    type="password"
                    name="password_confirmation"
                    autocomplete="new-password"
                    minlength="12"
                    required
                  />
                  <p :if={@error} class="login-error" role="alert">{@error}</p>
                  <button class="login-button" type="submit">Set password</button>
                </form>
              <% :message -> %>
                <h1 class="login-title">{@title}</h1>
                <p :if={@notice} class="login-notice" role="status">{@notice}</p>
                <p :if={@error} class="login-error" role="alert">{@error}</p>
                <p class="login-help"><a href="/login">Go to sign in</a></p>
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
  defp page_title(:account), do: "Your account"
  defp page_title(:reset), do: "Set a new password"
  defp page_title(:message), do: "Symphony"
end
