defmodule SymphonyElixirWeb.RequestGuards do
  @moduledoc """
  Request-level protections that run before routing.

    * `proxy_headers/2` - with `server.trust_proxy: true`, take the client IP and
      scheme from `X-Forwarded-For` / `X-Forwarded-Proto` (set by your TLS proxy),
      so per-IP rate limits and the `Secure` cookie flag see the real client.
    * `local_host_only/2` - in `:local` auth mode (no sign-in) only answer
      requests addressed to localhost. Blocks DNS-rebinding pages from driving
      the local operator's dashboard. `/mcp` is exempt while enabled: it
      always needs a token (`SymphonyElixirWeb.McpAuth`).
    * `mcp_host_only/2` - requests addressed to `server.mcp.host` only reach
      `/mcp`, so a proxy route for that host without sign-in in front (no IAP)
      can't expose the dashboard, even if it forwards every path.
  """

  import Plug.Conn

  alias SymphonyElixir.{Auth, Config}

  @local_hosts ["localhost", "127.0.0.1", "::1", "[::1]"]

  @spec proxy_headers(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def proxy_headers(conn, _opts) do
    if Config.settings!().server.trust_proxy == true do
      conn
      |> put_forwarded_ip()
      |> put_forwarded_scheme()
    else
      conn
    end
  end

  @spec local_host_only(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def local_host_only(conn, _opts) do
    cond do
      Application.get_env(:symphony_elixir, :enforce_local_host, true) != true -> conn
      Auth.mode() != :local -> conn
      conn.host in @local_hosts -> conn
      mcp_request?(conn) and Config.settings!().server.mcp.enabled == true -> conn
      true -> conn |> send_resp(421, "Symphony without sign-in only answers on localhost.") |> halt()
    end
  end

  @spec mcp_host_only(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def mcp_host_only(conn, _opts) do
    case Config.settings!().server.mcp.host do
      host when is_binary(host) ->
        if String.downcase(conn.host) == host and not mcp_request?(conn),
          do: conn |> send_resp(404, "Not found") |> halt(),
          else: conn

      _ ->
        conn
    end
  end

  defp mcp_request?(conn), do: conn.path_info == ["mcp"]

  @doc """
  WebSocket origins accepted for LiveView in local mode.
  """
  @spec local_origins() :: [String.t()]
  def local_origins, do: ["//localhost", "//127.0.0.1", "//[::1]"]

  @spec https?(Plug.Conn.t()) :: boolean()
  def https?(conn), do: conn.scheme == :https

  # The proxy appends the address it received the request from, so the last
  # entry is the one our trusted proxy saw.
  defp put_forwarded_ip(conn) do
    with [value | _] <- get_req_header(conn, "x-forwarded-for"),
         last when is_binary(last) <- value |> String.split(",") |> List.last(),
         {:ok, ip} <- last |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      %{conn | remote_ip: ip}
    else
      _ -> conn
    end
  end

  defp put_forwarded_scheme(conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      ["https" | _] -> %{conn | scheme: :https}
      ["http" | _] -> %{conn | scheme: :http}
      _ -> conn
    end
  end
end
