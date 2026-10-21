defmodule SymphonyElixirWeb.Endpoint do
  @moduledoc """
  Phoenix endpoint for Symphony's optional observability UI and API.
  """

  use Phoenix.Endpoint, otp_app: :symphony_elixir

  # Encrypted and signed; holds only the signed-in account id and session version.
  @session_options [
    store: :cookie,
    key: "_symphony_elixir_key",
    signing_salt: "symphony-session",
    encryption_salt: "symphony-session-encryption",
    same_site: "Lax",
    http_only: true,
    max_age: 60 * 60 * 24 * 30
  ]

  @doc false
  @spec session_options() :: keyword()
  def session_options, do: @session_options

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: {__MODULE__, :log_level, []})

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:proxy_headers)
  plug(:mcp_host_only)
  plug(:local_host_only)
  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(:session)
  plug(SymphonyElixirWeb.Router)

  @doc """
  The request log level: `false` for password reset links, whose token is in
  the path, so the request line never carries it.
  """
  @spec log_level(Plug.Conn.t()) :: Logger.level() | false
  def log_level(%Plug.Conn{path_info: ["reset" | _]}), do: false
  def log_level(_conn), do: :info

  defp proxy_headers(conn, opts), do: SymphonyElixirWeb.RequestGuards.proxy_headers(conn, opts)
  defp local_host_only(conn, opts), do: SymphonyElixirWeb.RequestGuards.local_host_only(conn, opts)
  defp mcp_host_only(conn, opts), do: SymphonyElixirWeb.RequestGuards.mcp_host_only(conn, opts)

  # Built per request so the cookie is marked Secure whenever the request is https
  # (directly or via a trusted proxy).
  defp session(conn, _opts) do
    secure? = SymphonyElixirWeb.RequestGuards.https?(conn)
    Plug.Session.call(conn, Plug.Session.init(Keyword.put(@session_options, :secure, secure?)))
  end
end
