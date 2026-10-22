defmodule SymphonyElixirWeb.HealthController do
  @moduledoc """
  `GET /readyz`: 200 once the accounts store can read its document from the
  state store (Postgres in a cluster), 503 otherwise. No session or sign-in, so
  a Kubernetes readiness probe can call it.
  """

  use Phoenix.Controller, formats: []

  alias Plug.Conn

  @spec ready(Conn.t(), map()) :: Conn.t()
  def ready(conn, _params) do
    if SymphonyElixir.Users.readable?() do
      conn |> Conn.put_resp_content_type("text/plain") |> Conn.send_resp(200, "ok")
    else
      conn |> Conn.put_resp_content_type("text/plain") |> Conn.send_resp(503, "not ready")
    end
  end
end
