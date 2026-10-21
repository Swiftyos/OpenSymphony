defmodule SymphonyElixirWeb.RunnerAuth do
  @moduledoc """
  Guards the runner protocol (`/runner/v1/runs/:run_id/...`).

  The run registry is the source of truth, so a runner keeps working (and can
  report to a restarted controller) without the controller having the run in
  its running set. A request is accepted only when:

    * the registry has a run with this id (`404` otherwise),
    * the credential is the HMAC for the run's current epoch (`401` for a
      missing or forged token): either `Authorization: Bearer <token>` or HTTP
      basic auth with the token as the password, which is what `git` sends for
      a URL like `https://x-access-token:<token>@host/...`, and
    * that epoch is the current one — a token for an earlier run of the issue
      is fenced with `409 {"error": "stale_epoch"}`.

  Once the run's `finished` event has been applied every endpoint answers
  `409 {"error": "finished"}`; see `SymphonyElixir.RunnerCommands`.

  No cookies are read and no CSRF applies: runners are processes, not browsers.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias SymphonyElixir.RunnerCommands
  alias SymphonyElixir.RunRegistry
  alias SymphonyElixir.RunToken

  @spec init(term()) :: term()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    run_id = conn.path_params["run_id"]

    case find_run(run_id) do
      nil ->
        deny(conn, 404, "run_not_found")

      {issue_id, entry} ->
        authorize(conn, run_id, issue_id, entry)
    end
  end

  # One ETS lookup in the registry's cache, however many runs there are.
  defp find_run(run_id), do: RunRegistry.find_run(run_id)

  defp authorize(conn, run_id, issue_id, entry) do
    token = credential(conn)

    cond do
      RunToken.verify(run_id, entry.epoch, token) ->
        # After a controller restart the in-memory bookkeeping is gone; restore
        # the run's persisted seq so the runner's outbox replay stays idempotent.
        RunnerCommands.seed(run_id, entry.last_seq, entry.finished)

        if RunnerCommands.finished?(run_id) do
          deny(conn, 409, "finished")
        else
          conn
          |> assign(:run_id, run_id)
          |> assign(:issue_id, issue_id)
          |> assign(:identifier, entry.metadata[:identifier] || issue_id)
          |> assign(:backend, entry.metadata[:backend])
          |> assign(:epoch, entry.epoch)
          |> assign(:run, entry)
        end

      RunToken.verify_any_epoch(run_id, token, entry.epoch) ->
        deny(conn, 409, "stale_epoch")

      true ->
        deny(conn, 401, "unauthorized")
    end
  end

  defp credential(conn) do
    with [header | _] <- get_req_header(conn, "authorization"),
         [scheme, credential] <- String.split(header, " ", parts: 2) do
      case String.downcase(scheme) do
        "bearer" -> String.trim(credential)
        "basic" -> basic_token(credential)
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  # Git's credential helper puts the run token after the first colon; the user
  # name (`x-access-token`) is ignored.
  defp basic_token(encoded) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [_user, token] <- String.split(decoded, ":", parts: 2),
         token when token != "" <- String.trim(token) do
      token
    else
      _ -> nil
    end
  end

  defp deny(conn, status, error) do
    conn
    |> maybe_challenge(status)
    |> put_status(status)
    |> json(%{error: error})
    |> halt()
  end

  # Without a challenge, git does not retry with the basic credential from a
  # clone URL; the bearer token is unaffected because it is sent up front.
  defp maybe_challenge(conn, 401), do: put_resp_header(conn, "www-authenticate", ~s(Basic realm="symphony"))
  defp maybe_challenge(conn, _status), do: conn
end
