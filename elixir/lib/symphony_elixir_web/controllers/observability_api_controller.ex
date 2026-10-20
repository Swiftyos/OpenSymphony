defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter, PrometheusMetrics, Visibility}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    payload = Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
    json(conn, Visibility.filter_payload(payload, conn.assigns[:current_user]))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        case Visibility.filter_issue(payload, conn.assigns[:current_user], issue_identifier) do
          {:ok, visible} -> json(conn, visible)
          :hidden -> error_response(conn, 404, "issue_not_found", "Issue not found")
        end

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @doc """
  Asks for a delayed restart: no new agent runs, then a restart once the
  running ones finish. Admins only (or the server.api_token).
  """
  @spec request_restart(Conn.t(), map()) :: Conn.t()
  def request_restart(conn, _params) do
    restart_action(conn, &SymphonyElixir.Orchestrator.request_delayed_restart(&1, orchestrator()))
  end

  @spec cancel_restart(Conn.t(), map()) :: Conn.t()
  def cancel_restart(conn, _params) do
    restart_action(conn, fn _requested_by -> SymphonyElixir.Orchestrator.cancel_delayed_restart(orchestrator()) end)
  end

  # A signed-in admin, or no user at all: the request came with server.api_token.
  defp restart_action(conn, action) do
    case conn.assigns[:current_user] do
      %{admin: true} = user -> restart_response(conn, action.(user.username || user.email || "admin"))
      nil -> restart_response(conn, action.("api token"))
      _user -> error_response(conn, 403, "forbidden", "Only admins can restart Symphony")
    end
  end

  defp restart_response(conn, :unavailable), do: error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
  defp restart_response(conn, payload), do: conn |> put_status(202) |> json(%{delayed_restart: payload})

  @spec metrics(Conn.t(), map()) :: Conn.t()
  def metrics(conn, _params) do
    body = PrometheusMetrics.render()

    conn
    |> put_resp_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
    |> send_resp(200, body)
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
