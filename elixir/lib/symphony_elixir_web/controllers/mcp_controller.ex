defmodule SymphonyElixirWeb.McpController do
  @moduledoc """
  The MCP endpoint (Streamable HTTP transport, JSON responses) at `/mcp`.

  Stateless: each `POST` carries one JSON-RPC message and gets its answer as
  `application/json`; notifications get `202`. There's no server-to-client
  stream, so `GET` and `DELETE` are `405`. `SymphonyElixirWeb.McpAuth` has already
  checked the bearer token and assigned `:current_user` and `:mcp_token`.

  Methods: `initialize`, `ping`, `tools/list`, `tools/call`, `resources/list`,
  `resources/read` (the manual, `SymphonyElixirWeb.Mcp.Manual`).
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.Mcp.{Manual, Tools}

  @protocol_versions ["2025-11-25", "2025-06-18", "2025-03-26"]
  @latest_version hd(@protocol_versions)

  @spec post(Conn.t(), map()) :: Conn.t()
  def post(conn, _params) do
    with :ok <- check_protocol_header(conn),
         {:ok, message} <- message(conn) do
      case handle(message, context(conn)) do
        :accepted -> send_resp(conn, 202, "")
        response -> json(conn, response)
      end
    else
      {:error, status, response} -> conn |> put_status(status) |> json(response)
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> put_status(405)
    |> json(%{error: %{code: "method_not_allowed", message: "Symphony's MCP endpoint takes POST only (no SSE stream)."}})
  end

  # Plug.Parsers put a JSON object body in body_params; arrays land under "_json".
  defp message(%Conn{body_params: %{"_json" => _batch}}),
    do: {:error, 400, rpc_error(nil, -32_600, "Batches aren't supported; send one JSON-RPC message per request.")}

  defp message(%Conn{body_params: %{"jsonrpc" => "2.0", "method" => method} = message}) when is_binary(method), do: {:ok, message}

  defp message(%Conn{body_params: %{"jsonrpc" => "2.0", "id" => _id, "result" => _result}}), do: {:ok, :client_response}
  defp message(%Conn{body_params: %{"jsonrpc" => "2.0", "id" => _id, "error" => _error}}), do: {:ok, :client_response}

  defp message(conn), do: {:error, 400, rpc_error(conn.body_params["id"], -32_600, "Expected a JSON-RPC 2.0 message.")}

  # After initialize, clients send the negotiated version on every request.
  defp check_protocol_header(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> :ok
      [version | _] when version in @protocol_versions -> :ok
      [version | _] -> {:error, 400, rpc_error(nil, -32_600, "Unsupported MCP-Protocol-Version #{version}.")}
    end
  end

  defp context(conn) do
    user = conn.assigns.current_user
    who = user.username || user.name

    # A token can do whatever its account can; Auth checks each change.
    %{
      user: user,
      actor: "#{who} via MCP",
      via: "via MCP"
    }
  end

  defp handle(:client_response, _ctx), do: :accepted
  defp handle(%{"id" => _id} = message, ctx), do: request(message, ctx)
  # Notifications (no id), e.g. notifications/initialized: nothing to answer.
  defp handle(_notification, _ctx), do: :accepted

  defp request(%{"id" => id, "method" => "initialize"} = message, ctx) do
    requested = get_in(message, ["params", "protocolVersion"])

    result(id, %{
      protocolVersion: if(requested in @protocol_versions, do: requested, else: @latest_version),
      capabilities: %{tools: %{listChanged: false}, resources: %{listChanged: false, subscribe: false}},
      serverInfo: %{name: "agent-factory", title: "Agent Factory", version: version()},
      instructions: instructions(ctx)
    })
  end

  defp request(%{"id" => id, "method" => "ping"}, _ctx), do: result(id, %{})

  defp request(%{"id" => id, "method" => "tools/list"}, _ctx), do: result(id, %{tools: Tools.list()})

  defp request(%{"id" => id, "method" => "resources/list"}, _ctx), do: result(id, %{resources: Manual.resources()})

  defp request(%{"id" => id, "method" => "resources/templates/list"}, _ctx), do: result(id, %{resourceTemplates: []})

  defp request(%{"id" => id, "method" => "resources/read", "params" => %{"uri" => uri}}, _ctx) when is_binary(uri) do
    case Manual.read(uri) do
      {:ok, text} -> result(id, %{contents: [%{uri: uri, mimeType: "text/markdown", text: text}]})
      :error -> rpc_error(id, -32_002, "Resource not found: #{uri}")
    end
  end

  defp request(%{"id" => id, "method" => "tools/call", "params" => %{"name" => name} = params}, ctx) when is_binary(name) do
    args = params["arguments"] || %{}

    cond do
      not Tools.known?(name) ->
        rpc_error(id, -32_602, "Unknown tool: #{name}")

      not is_map(args) ->
        rpc_error(id, -32_602, "arguments must be an object")

      true ->
        case Tools.call(name, args, ctx) do
          {:ok, structured} ->
            result(id, %{content: [%{type: "text", text: Jason.encode!(structured)}], structuredContent: structured, isError: false})

          {:error, message} ->
            result(id, %{content: [%{type: "text", text: message}], isError: true})
        end
    end
  end

  defp request(%{"id" => id, "method" => "tools/call"}, _ctx), do: rpc_error(id, -32_602, "tools/call needs params.name")

  defp request(%{"id" => id, "method" => method}, _ctx), do: rpc_error(id, -32_601, "Method not found: #{method}")

  defp result(id, result), do: %{jsonrpc: "2.0", id: id, result: result}

  defp rpc_error(id, code, message), do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  defp instructions(ctx) do
    reach =
      if ctx.user.admin or ctx.user.local,
        do: "everything",
        else: Enum.join(Enum.map(ctx.user.teams, & &1.key) ++ Enum.map(ctx.user.projects, &("project:" <> &1)), ", ")

    """
    Symphony runs coding agents on Linear issues through factory flows: stages (a Linear state plus a factory/* label) joined by transitions. \
    You act as #{ctx.user.name}, with their permissions (#{reach}): you may do what they may do in the dashboard. \
    When someone asks what this is, how Symphony works or how to use it, call get_manual (also the resource symphony://manual) and explain from it. \
    For the live state start with symphony_status and list_flows. To change a flow, get_flow, edit the definition, and save_flow with the version you read.\
    """
  end

  defp version, do: :symphony_elixir |> Application.spec(:vsn) |> to_string()
end
