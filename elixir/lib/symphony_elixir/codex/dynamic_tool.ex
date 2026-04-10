defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Legacy helper retained for tests around the previous Codex dynamic tool contract.
  """

  alias SymphonyElixir.Linear.GraphqlTool

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      name when is_binary(name) ->
        if name == GraphqlTool.tool_name() do
          GraphqlTool.execute(arguments, opts)
        else
          failure_response(%{
            "error" => %{
              "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
              "supportedTools" => supported_tool_names()
            }
          })
        end

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [GraphqlTool.tool_spec()]
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

  defp supported_tool_names do
    GraphqlTool.supported_tool_names()
  end
end
