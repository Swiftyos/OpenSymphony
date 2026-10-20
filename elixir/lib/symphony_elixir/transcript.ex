defmodule SymphonyElixir.Transcript do
  @moduledoc """
  A running, chat-style record of what each issue's agents have done: their
  messages, the commands and tools they ran, and the stage moves Symphony made.

  Entries are kept in memory per issue identifier (the newest #{400}), fed from
  the agent runner as Codex, Claude Code, and OpenCode events arrive. Streaming
  deltas are skipped; each entry is a finished message or action.
  """

  use GenServer

  @table :symphony_transcripts
  @max_entries 400
  @max_text 8_000

  @type entry :: %{at: DateTime.t(), kind: String.t(), text: String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  The issue's entries, oldest first.
  """
  @spec entries(String.t() | nil) :: [entry()]
  def entries(identifier) when is_binary(identifier) do
    with true <- ready?(), [{^identifier, entries}] <- :ets.lookup(@table, identifier) do
      Enum.reverse(entries)
    else
      _ -> []
    end
  end

  def entries(_identifier), do: []

  @doc """
  Records an agent event (as the agent runner receives it), if it is one a
  person would want to read.
  """
  @spec record(String.t() | nil, map()) :: :ok
  def record(identifier, update) when is_binary(identifier) and is_map(update) do
    case entry(update) do
      {kind, text} -> append(identifier, kind, text)
      nil -> :ok
    end
  end

  def record(_identifier, _update), do: :ok

  @doc """
  Records a line from Symphony itself (a stage starting, a move, a rejection).
  """
  @spec note(String.t() | nil, String.t()) :: :ok
  def note(identifier, text) when is_binary(identifier) and is_binary(text), do: append(identifier, "symphony", text)
  def note(_identifier, _text), do: :ok

  @doc false
  @spec reset() :: :ok
  def reset do
    if ready?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  defp append(identifier, kind, text) do
    if ready?() do
      item = %{at: DateTime.utc_now(), kind: kind, text: String.slice(String.trim(text), 0, @max_text)}

      existing =
        case :ets.lookup(@table, identifier),
          do: (
            [{_, list}] -> list
            [] -> []
          )

      :ets.insert(@table, {identifier, Enum.take([item | existing], @max_entries)})
    end

    :ok
  end

  defp ready?, do: :ets.whereis(@table) != :undefined

  # ------------------------------------------------------------------ events

  @doc false
  @spec entry(map()) :: {String.t(), String.t()} | nil
  def entry(update) do
    case payload(update) do
      %{"method" => "item/completed", "params" => %{"item" => item}} -> codex_item(item)
      %{"method" => "turn/failed"} = p -> {"error", "Turn failed: " <> inspect(get_in(p, ["params", "error"]))}
      %{"payload" => %{"type" => "message.part.updated", "properties" => %{"part" => part}}} -> part(part)
      _ -> nil
    end
  end

  defp payload(%{payload: %{} = payload}), do: payload
  defp payload(%{payload: payload}) when is_binary(payload), do: decode(payload)
  defp payload(%{raw: raw}) when is_binary(raw), do: decode(raw)
  defp payload(_update), do: nil

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> map
      _ -> nil
    end
  end

  # Codex items, when they finish.
  defp codex_item(%{"type" => "agentMessage", "text" => text}) when is_binary(text) and text != "", do: {"agent", text}

  defp codex_item(%{"type" => "commandExecution"} = item) do
    command = item["command"] |> List.wrap() |> Enum.join(" ")
    exit = if is_integer(item["exitCode"]), do: " (exit #{item["exitCode"]})", else: ""
    output = item["aggregatedOutput"] |> to_string() |> String.trim() |> tail(1_500)
    {"tool", "$ " <> command <> exit <> if(output == "", do: "", else: "\n" <> output)}
  end

  defp codex_item(%{"type" => "fileChange", "changes" => changes}) when is_list(changes) do
    {"tool", "Edited " <> Enum.map_join(changes, ", ", &(&1["path"] || "a file"))}
  end

  defp codex_item(%{"type" => "reasoning"} = item) do
    case item["summary"] |> List.wrap() |> Enum.map_join("\n", &reasoning_text/1) |> String.trim() do
      "" -> nil
      text -> {"thinking", text}
    end
  end

  defp codex_item(%{"type" => "mcpToolCall"} = item), do: {"tool", "#{item["server"]}/#{item["tool"]}"}
  defp codex_item(%{"type" => "dynamicToolCall"} = item), do: {"tool", "#{item["tool"] || item["name"] || "tool"}"}
  defp codex_item(%{"type" => "webSearch"} = item), do: {"tool", "Searched the web: #{item["query"]}"}
  defp codex_item(_item), do: nil

  defp reasoning_text(%{"text" => text}) when is_binary(text), do: text
  defp reasoning_text(text) when is_binary(text), do: text
  defp reasoning_text(_part), do: ""

  # Claude Code and OpenCode message parts.
  defp part(%{"type" => "text", "text" => text}) when is_binary(text) and text != "", do: {"agent", text}
  defp part(%{"type" => "reasoning", "text" => text}) when is_binary(text) and text != "", do: {"thinking", text}

  defp part(%{"type" => "tool", "tool" => tool} = part) when is_binary(tool) do
    input = part["input"] || get_in(part, ["state", "input"])
    {"tool", tool <> if(is_binary(input) and input not in ["", "{}"], do: " " <> input, else: "")}
  end

  defp part(_part), do: nil

  defp tail(text, max) do
    if String.length(text) > max, do: "…" <> String.slice(text, -max, max), else: text
  end
end
