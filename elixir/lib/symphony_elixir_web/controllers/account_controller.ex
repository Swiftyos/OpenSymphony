defmodule SymphonyElixirWeb.AccountController do
  @moduledoc """
  The MCP setup page: the person's MCP token, install commands for each agent
  harness with it filled in, and a button that rotates it. Sign-in itself is
  Google IAP's (`SymphonyElixirWeb.UserAuth`).
  """

  use Phoenix.Controller, formats: [:html]
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Plug.CSRFProtection
  alias SymphonyElixir.{Auth, Config, McpTokens, Users}
  alias SymphonyElixirWeb.McpSetup

  @spec account(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def account(conn, _params), do: redirect(conn, to: if(mcp_enabled?(), do: "/account/mcp", else: "/"))

  @spec mcp(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def mcp(conn, _params) do
    user = conn.assigns.current_user

    with true <- mcp_enabled?(),
         {:ok, secret, token} <- McpTokens.current(token_owner(user)) do
      welcomed(user)
      render_page(conn, user, secret, token, nil)
    else
      _ -> redirect(conn, to: "/")
    end
  end

  @doc """
  Issues a new token for the signed-in person; the old one stops working.
  """
  @spec rotate_mcp_token(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rotate_mcp_token(conn, _params) do
    user = conn.assigns.current_user

    with true <- mcp_enabled?(),
         {:ok, secret, token} <- McpTokens.rotate(token_owner(user)) do
      render_page(conn, user, secret, token, "New token issued. The old one stopped working; update your agents with the commands below.")
    else
      _ -> redirect(conn, to: "/")
    end
  end

  # Seeing the setup page counts as having seen the first-visit popup.
  defp welcomed(%Auth.User{local: true}), do: :ok
  defp welcomed(%Auth.User{id: id}), do: Users.mark_mcp_welcomed(id)

  defp token_owner(%Auth.User{local: true}), do: "local"
  defp token_owner(%Auth.User{id: id}), do: id

  defp mcp_enabled?, do: Config.settings!().server.mcp.enabled == true

  defp render_page(conn, user, secret, token, notice) do
    assigns = %{
      user: user,
      secret: secret,
      token: token,
      notice: notice,
      mcp_url: McpSetup.url("#{conn.scheme}://#{conn.host}:#{conn.port}"),
      csrf_token: CSRFProtection.get_csrf_token(),
      instance: Config.instance_name() || "Symphony"
    }

    html(conn, assigns |> page() |> Safe.to_iodata())
  end

  defp page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>MCP setup · {@instance}</title>
        <link rel="stylesheet" href={SymphonyElixirWeb.StaticAssets.url("/dashboard.css")} />
      </head>
      <body>
        <main class="login-shell">
          <div class="login-card is-wide">
            <img :if={is_binary(SymphonyElixir.Config.instance_logo())} class="brand-logo login-logo" src="/branding/logo" alt="" />
            <h1 class="login-title">Connect your agents</h1>
            <p class="login-help">
              Agents watch and steer {@instance} at <code>{@mcp_url}</code>
              with your token. It can do what you can do in the dashboard, and stops working if your account is disabled.
            </p>
            <p :if={@notice} class="login-notice" role="status">{@notice}</p>
            <div class="mcp-token-row">
              <span class="login-label">Your token</span>
              <code class="mcp-token">{@secret}</code>
              <span class="login-help">
                Issued {String.slice(@token.created_at, 0, 10)}
                · {if @token.last_used_at, do: "last used #{String.slice(@token.last_used_at, 0, 10)}", else: "not used yet"}
              </span>
            </div>
            <McpSetup.instructions url={@mcp_url} token={@secret} />
            <form class="login-form" method="post" action="/account/mcp-token/rotate">
              <input type="hidden" name="_csrf_token" value={@csrf_token} />
              <button
                class="login-button"
                type="submit"
                onclick="return confirm('Issue a new token? Agents using the current one stop working until you update them.')"
              >
                Rotate token
              </button>
            </form>
            <p class="login-help"><a href="/">Back to the dashboard</a></p>
          </div>
        </main>
      </body>
    </html>
    """
  end
end
