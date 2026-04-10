defmodule SymphonyElixir.Linear.GraphqlTool do
  @moduledoc false

  alias SymphonyElixir.Linear.Client

  @tool_name "linear_graphql"
  @description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @spec description() :: String.t()
  def description, do: @description

  @spec input_schema() :: map()
  def input_schema, do: @input_schema

  @spec tool_spec() :: map()
  def tool_spec do
    %{
      "name" => tool_name(),
      "description" => description(),
      "inputSchema" => input_schema()
    }
  end

  @spec supported_tool_names() :: [String.t()]
  def supported_tool_names, do: [tool_name()]

  @spec execute(term(), keyword()) :: map()
  def execute(arguments, opts \\ []) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  @spec open_code_tool_source() :: String.t()
  def open_code_tool_source do
    missing_query = tool_error_payload(:missing_query) |> Jason.encode!(pretty: true)
    missing_api_key = tool_error_payload(:missing_linear_api_token) |> Jason.encode!(pretty: true)
    transport_failure = transport_failure_message()
    http_failure_prefix = http_failure_message_prefix()

    """
    import { tool } from "@opencode-ai/plugin";
    import { z } from "zod";

    const ENDPOINT = process.env.SYMPHONY_LINEAR_ENDPOINT || "https://api.linear.app/graphql";
    const API_KEY = process.env.SYMPHONY_LINEAR_API_KEY;
    const MISSING_QUERY_PAYLOAD = #{inspect(missing_query)};
    const MISSING_API_KEY_PAYLOAD = #{inspect(missing_api_key)};
    const TRANSPORT_FAILURE_MESSAGE = #{inspect(transport_failure)};
    const HTTP_FAILURE_PREFIX = #{inspect(http_failure_prefix)};

    const format = (value: unknown) => JSON.stringify(value, null, 2);

    const fail = (payload: unknown): never => {
      throw new Error(format(payload));
    };

    export default tool({
      description: #{inspect(description())},
      args: {
        query: z.string().min(1),
        variables: z.record(z.string(), z.unknown()).nullable().optional(),
      },
      async execute(args) {
        const query = args.query.trim();

        if (!query) {
          fail(JSON.parse(MISSING_QUERY_PAYLOAD));
        }

        if (!API_KEY) {
          fail(JSON.parse(MISSING_API_KEY_PAYLOAD));
        }

        try {
          const response = await fetch(ENDPOINT, {
            method: "POST",
            headers: {
              Authorization: API_KEY,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              query,
              variables: args.variables ?? {},
            }),
          });

          const json = await response.json();

          if (!response.ok) {
            fail({
              error: {
                message: `${HTTP_FAILURE_PREFIX}${response.status}.`,
                status: response.status,
                body: json,
              },
            });
          }

          if (Array.isArray(json?.errors) && json.errors.length > 0) {
            fail(json);
          }

          return format(json);
        } catch (error) {
          fail({
            error: {
              message: TRANSPORT_FAILURE_MESSAGE,
              reason: error instanceof Error ? error.message : String(error),
            },
          });
        }
      },
    });
    """
  end

  @spec claude_mcp_server_source() :: String.t()
  def claude_mcp_server_source do
    missing_query = tool_error_payload(:missing_query) |> Jason.encode!(pretty: true)
    invalid_arguments = tool_error_payload(:invalid_arguments) |> Jason.encode!(pretty: true)
    invalid_variables = tool_error_payload(:invalid_variables) |> Jason.encode!(pretty: true)
    missing_api_key = tool_error_payload(:missing_linear_api_token) |> Jason.encode!(pretty: true)
    transport_failure = transport_failure_message()
    http_failure_prefix = http_failure_message_prefix()
    unsupported = tool_error_payload({:unsupported_tool, supported_tool_names()}) |> Jason.encode!(pretty: true)

    """
    #!/usr/bin/env node
    const TOOL_NAME = #{inspect(tool_name())};
    const DESCRIPTION = #{inspect(description())};
    const INPUT_SCHEMA = #{Jason.encode!(input_schema())};
    const MISSING_QUERY_PAYLOAD = #{inspect(missing_query)};
    const INVALID_ARGUMENTS_PAYLOAD = #{inspect(invalid_arguments)};
    const INVALID_VARIABLES_PAYLOAD = #{inspect(invalid_variables)};
    const MISSING_API_KEY_PAYLOAD = #{inspect(missing_api_key)};
    const UNSUPPORTED_PAYLOAD = #{inspect(unsupported)};
    const TRANSPORT_FAILURE_MESSAGE = #{inspect(transport_failure)};
    const HTTP_FAILURE_PREFIX = #{inspect(http_failure_prefix)};
    const ENDPOINT = process.env.SYMPHONY_LINEAR_ENDPOINT || "https://api.linear.app/graphql";
    const API_KEY = process.env.SYMPHONY_LINEAR_API_KEY;

    let buffer = "";

    function send(message) {
      const payload = JSON.stringify(message);
      process.stdout.write(`Content-Length: ${Buffer.byteLength(payload, "utf8")}\\r\\n\\r\\n${payload}`);
    }

    function sendResult(id, result) {
      send({ jsonrpc: "2.0", id, result });
    }

    function sendError(id, code, message, data) {
      send({ jsonrpc: "2.0", id, error: { code, message, data } });
    }

    function parseJson(value, fallback) {
      try {
        return JSON.parse(value);
      } catch (_error) {
        return fallback;
      }
    }

    function format(value) {
      return JSON.stringify(value, null, 2);
    }

    function successResponse(payload) {
      const text = format(payload);
      return { content: [{ type: "text", text }], isError: false };
    }

    function failureResponse(payload) {
      const text = format(payload);
      return { content: [{ type: "text", text }], isError: true };
    }

    function normalizeArguments(args) {
      if (typeof args === "string") {
        const query = args.trim();
        if (!query) {
          return { ok: false, payload: parseJson(MISSING_QUERY_PAYLOAD, { error: { message: "Missing query" } }) };
        }

        return { ok: true, query, variables: {} };
      }

      if (!args || typeof args !== "object" || Array.isArray(args)) {
        return { ok: false, payload: parseJson(INVALID_ARGUMENTS_PAYLOAD, { error: { message: "Invalid arguments" } }) };
      }

      const query = typeof args.query === "string" ? args.query.trim() : "";

      if (!query) {
        return { ok: false, payload: parseJson(MISSING_QUERY_PAYLOAD, { error: { message: "Missing query" } }) };
      }

      const variables = args.variables ?? {};

      if (variables === null) {
        return { ok: true, query, variables: {} };
      }

      if (typeof variables !== "object" || Array.isArray(variables)) {
        return { ok: false, payload: parseJson(INVALID_VARIABLES_PAYLOAD, { error: { message: "Invalid variables" } }) };
      }

      return { ok: true, query, variables };
    }

    async function executeTool(args) {
      const normalized = normalizeArguments(args);

      if (!normalized.ok) {
        return failureResponse(normalized.payload);
      }

      if (!API_KEY) {
        return failureResponse(parseJson(MISSING_API_KEY_PAYLOAD, { error: { message: "Missing API key" } }));
      }

      try {
        const response = await fetch(ENDPOINT, {
          method: "POST",
          headers: {
            Authorization: API_KEY,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            query: normalized.query,
            variables: normalized.variables,
          }),
        });

        const payload = await response.json();

        if (!response.ok) {
          return failureResponse({
            error: {
              message: `${HTTP_FAILURE_PREFIX}${response.status}.`,
              status: response.status,
              body: payload,
            },
          });
        }

        if (Array.isArray(payload?.errors) && payload.errors.length > 0) {
          return failureResponse(payload);
        }

        return successResponse(payload);
      } catch (error) {
        return failureResponse({
          error: {
            message: TRANSPORT_FAILURE_MESSAGE,
            reason: error instanceof Error ? error.message : String(error),
          },
        });
      }
    }

    async function handleMessage(message) {
      const id = message?.id ?? null;
      const method = message?.method;

      if (method === "initialize") {
        const protocolVersion =
          typeof message?.params?.protocolVersion === "string" && message.params.protocolVersion !== ""
            ? message.params.protocolVersion
            : "2024-11-05";

        sendResult(id, {
          protocolVersion,
          capabilities: { tools: {} },
          serverInfo: {
            name: "symphony-linear-graphql",
            version: "0.1.0",
          },
        });
        return;
      }

      if (method === "notifications/initialized") {
        return;
      }

      if (method === "tools/list") {
        sendResult(id, {
          tools: [
            {
              name: TOOL_NAME,
              description: DESCRIPTION,
              inputSchema: INPUT_SCHEMA,
            },
          ],
        });
        return;
      }

      if (method === "tools/call") {
        const name = message?.params?.name;

        if (name !== TOOL_NAME) {
          sendResult(id, failureResponse(parseJson(UNSUPPORTED_PAYLOAD, { error: { message: "Unsupported tool" } })));
          return;
        }

        const response = await executeTool(message?.params?.arguments);
        sendResult(id, response);
        return;
      }

      if (id !== null) {
        sendError(id, -32601, "Method not found", { method });
      }
    }

    function readMessages() {
      while (true) {
        const headerEnd = buffer.indexOf("\\r\\n\\r\\n");

        if (headerEnd === -1) {
          return;
        }

        const header = buffer.slice(0, headerEnd);
        const contentLengthLine = header
          .split("\\r\\n")
          .find((line) => line.toLowerCase().startsWith("content-length:"));

        if (!contentLengthLine) {
          buffer = "";
          return;
        }

        const contentLength = Number(contentLengthLine.split(":")[1]?.trim() || "");

        if (!Number.isFinite(contentLength) || contentLength < 0) {
          buffer = "";
          return;
        }

        const bodyStart = headerEnd + 4;

        if (buffer.length < bodyStart + contentLength) {
          return;
        }

        const body = buffer.slice(bodyStart, bodyStart + contentLength);
        buffer = buffer.slice(bodyStart + contentLength);

        let message;

        try {
          message = JSON.parse(body);
        } catch (error) {
          sendError(null, -32700, "Parse error", { reason: String(error) });
          continue;
        }

        Promise.resolve(handleMessage(message)).catch((error) => {
          if (message?.id !== null && message?.id !== undefined) {
            sendError(message.id, -32603, "Internal error", { reason: String(error) });
          }
        });
      }
    }

    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      buffer += chunk;
      readMessages();
    });
    process.stdin.on("end", () => process.exit(0));
    process.stdin.resume();
    """
  end

  @spec tool_error_payload(term()) :: map()
  def tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  def tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  def tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  def tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `tracker.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  def tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "#{http_failure_message_prefix()}#{status}.",
        "status" => status
      }
    }
  end

  def tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => transport_failure_message(),
        "reason" => inspect(reason)
      }
    }
  end

  def tool_error_payload({:unsupported_tool, supported_tools}) when is_list(supported_tools) do
    %{
      "error" => %{
        "message" => "Unsupported dynamic tool.",
        "supportedTools" => supported_tools
      }
    }
  end

  def tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  @spec normalize_arguments(term()) :: {:ok, String.t(), map()} | {:error, term()}
  def normalize_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  def normalize_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      nil -> {:ok, %{}}
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp transport_failure_message do
    "Linear GraphQL request failed before receiving a successful response."
  end

  defp http_failure_message_prefix do
    "Linear GraphQL request failed with HTTP "
  end
end
