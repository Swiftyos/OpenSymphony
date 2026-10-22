defmodule SymphonyElixirWeb.UsersImportController do
  @moduledoc """
  `POST /admin/users/import`: provisions accounts from a CSV of Linear team
  roles (`SymphonyElixir.Users.Import`) inside the running controller, so the
  accounts store it holds in memory is the one that changes.

  The body is the CSV itself (`Content-Type: text/csv`); `?dry_run=true`
  reports without writing and `?skip_invalid=true` writes the valid rows even
  when others have problems. It takes a global admin's MCP token
  (`Authorization: Bearer`, checked by `SymphonyElixirWeb.McpAuth`), so it can
  be called through a port-forward to the controller, without IAP; behind the
  load balancer the path is still behind IAP. Answers with the import's report
  as JSON.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.Policy
  alias SymphonyElixir.Users.Import

  @max_body_bytes 2_000_000

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    user = conn.assigns.current_user

    with :ok <- Policy.authorize(user, :control),
         {:ok, body, conn} <- Conn.read_body(conn, length: @max_body_bytes),
         true <- String.contains?(body, "\n") || {:error, :empty_csv},
         opts = [dry_run: truthy?(params["dry_run"]), skip_invalid: truthy?(params["skip_invalid"]), by: "#{user.username || user.name} (import)"],
         {:ok, report} <- Import.from_csv(body, opts) do
      json(conn, report)
    else
      {:error, reason} when reason in [:read_only, :not_admin] ->
        error(conn, 403, "forbidden", "Only admins can import accounts.")

      {:more, _partial, conn} ->
        error(conn, 413, "too_large", "The CSV is larger than #{@max_body_bytes} bytes.")

      {:error, reason} ->
        Logger.warning("Accounts import refused reason=#{inspect(reason)}")
        error(conn, 422, "invalid_import", inspect(reason))
    end
  end

  defp truthy?(value), do: value in ["true", "1", "yes"]

  defp error(conn, status, code, message), do: conn |> put_status(status) |> json(%{error: %{code: code, message: message}})
end
