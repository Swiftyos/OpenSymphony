defmodule SymphonyElixirWeb.AgentMessagesController do
  @moduledoc """
  JSON API for dashboard messages to the agent working on an issue
  (`SymphonyElixir.AgentInbox`).

    * `GET /api/v1/issues/:issue_identifier/messages` - the issue's messages.
    * `POST /api/v1/issues/:issue_identifier/messages` with `{"text": "..."}` -
      sends one. The body must be JSON, so a plain cross-site form can't post.

  Viewers who can't see the issue get `404`; those who can see it but may not
  move it (guests, other teams' members) get `403` on `POST`.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{AgentInbox, Auth}
  alias SymphonyElixirWeb.Visibility

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, %{"issue_identifier" => identifier}) do
    if visible?(conn, identifier) do
      json(conn, %{issue_identifier: identifier, messages: AgentInbox.messages(identifier)})
    else
      not_found(conn)
    end
  end

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, %{"issue_identifier" => identifier} = params) do
    user = conn.assigns[:current_user]

    cond do
      not visible?(conn, identifier) ->
        not_found(conn)

      not json_request?(conn) ->
        error_response(conn, 415, "unsupported_media_type", "Send the message as application/json.")

      not Auth.can_message_agent?(user, identifier) ->
        error_response(conn, 403, "forbidden", "You can't message the agent on this issue.")

      true ->
        case AgentInbox.send_message(identifier, params["text"], author(user)) do
          {:ok, message} -> conn |> put_status(201) |> json(%{message: message})
          {:error, reason} -> send_error(conn, reason)
        end
    end
  end

  defp send_error(conn, :empty_message), do: error_response(conn, 422, "empty_message", "The message is empty.")

  defp send_error(conn, :message_too_long),
    do: error_response(conn, 422, "message_too_long", "The message is longer than 8000 characters.")

  defp send_error(conn, :unavailable), do: error_response(conn, 503, "inbox_unavailable", "Messaging is unavailable.")
  defp send_error(conn, reason), do: error_response(conn, 422, to_string(reason), "The message couldn't be sent.")

  defp visible?(conn, identifier), do: Visibility.filter_issue(%{}, conn.assigns[:current_user], identifier) != :hidden

  defp json_request?(conn) do
    case Conn.get_req_header(conn, "content-type") do
      [type | _] -> type |> String.downcase() |> String.starts_with?("application/json")
      [] -> false
    end
  end

  defp author(%Auth.User{} = user), do: user.name || user.email || user.username || "Someone"
  defp author(_user), do: "API client"

  defp not_found(conn), do: error_response(conn, 404, "issue_not_found", "Issue not found")

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
