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
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:proxy_headers)
  plug(:local_host_only)
  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(:session)
  plug(SymphonyElixirWeb.Router)

  defp proxy_headers(conn, opts), do: SymphonyElixirWeb.RequestGuards.proxy_headers(conn, opts)
  defp local_host_only(conn, opts), do: SymphonyElixirWeb.RequestGuards.local_host_only(conn, opts)

  # Built per request so the cookie is marked Secure whenever the request is https
  # (directly or via a trusted proxy).
  defp session(conn, _opts) do
    secure? = SymphonyElixirWeb.RequestGuards.https?(conn)
    Plug.Session.call(conn, Plug.Session.init(Keyword.put(@session_options, :secure, secure?)))
  end
end
