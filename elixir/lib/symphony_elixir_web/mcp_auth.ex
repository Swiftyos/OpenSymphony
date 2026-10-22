defmodule SymphonyElixirWeb.McpAuth do
  @moduledoc """
  Guards `/mcp`. It's built to face the internet without a sign-in proxy in front:

    * `404` unless `server.mcp.enabled` is true
    * per-client-IP rate limit (`SymphonyElixirWeb.RateLimit`, `:mcp`)
    * requests carrying an `Origin` header (browsers) must come from an allowed
      origin (`server.mcp.allowed_origins` or `server.public_url`), which stops
      web pages, including DNS-rebinding ones, from driving it
    * `Authorization: Bearer <MCP token>` is required in every auth mode; the
      token's account is re-resolved on every request (`SymphonyElixir.Auth`),
      so disabled accounts and lost Linear roles take effect at once. The token
      can do what its account can.

  The MCP route sits outside IAP (agents can't do Google sign-in), so no IAP
  header is read here. No cookies are read either, so the dashboard's session
  can't be used here and CSRF doesn't apply. Assigns `:current_user` and
  `:mcp_token`.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  alias SymphonyElixir.{Auth, Config, McpTokens}

  @spec init(term()) :: term()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    settings = Config.settings!()

    with :ok <- enabled(settings),
         :ok <- origin_allowed(conn, settings),
         {:ok, secret} <- bearer(conn),
         {:ok, token} <- McpTokens.verify(secret),
         {:ok, user} <- resolve_user(token) do
      McpTokens.touch(token.id, client_ip(conn))

      conn
      |> assign(:current_user, user)
      |> assign(:mcp_token, token)
    else
      {:error, :disabled} -> deny(conn, 404, "not_found", "Route not found")
      {:error, :origin} -> deny(conn, 403, "forbidden_origin", "This origin may not call Symphony's MCP endpoint.")
      {:error, reason} -> unauthorized(conn, reason)
    end
  end

  defp enabled(settings), do: if(settings.server.mcp.enabled == true, do: :ok, else: {:error, :disabled})

  defp origin_allowed(conn, settings) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin | _] ->
        allowed = [settings.server.public_url | settings.server.mcp.allowed_origins] |> Enum.filter(&is_binary/1) |> Enum.map(&normalize_origin/1)
        if normalize_origin(origin) in allowed, do: :ok, else: {:error, :origin}
    end
  end

  defp normalize_origin(origin), do: origin |> String.trim() |> String.trim_trailing("/") |> String.downcase()

  defp bearer(conn) do
    with [header | _] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme) do
      {:ok, String.trim(token)}
    else
      _ -> {:error, :missing_token}
    end
  end

  # Local-operator tokens only work while Symphony runs without sign-in.
  defp resolve_user(%{account_id: "local"}) do
    if Auth.mode() == :local, do: {:ok, Auth.local_user()}, else: {:error, :account_unavailable}
  end

  defp resolve_user(%{account_id: account_id}) do
    case Auth.user_for_id(account_id) do
      {:ok, user} -> {:ok, user}
      {:error, _reason} -> {:error, :account_unavailable}
    end
  end

  defp unauthorized(conn, reason) do
    if reason != :missing_token, do: Logger.warning("MCP auth refused reason=#{reason} ip=#{client_ip(conn)}")

    {error, message} =
      case reason do
        :missing_token -> {"invalid_request", "Send Authorization: Bearer <token>. Your token is on Symphony's MCP setup page (/account/mcp)."}
        :account_unavailable -> {"invalid_token", "This token's account can't use Symphony any more."}
        _ -> {"invalid_token", "That token isn't valid. It may have been rotated; your current token is on Symphony's MCP setup page (/account/mcp)."}
      end

    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="symphony-mcp", error="#{error}"))
    |> deny(401, "unauthorized", message)
  end

  defp deny(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
    |> halt()
  end

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
