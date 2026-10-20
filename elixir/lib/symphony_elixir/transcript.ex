defmodule SymphonyElixir.Transcript do
  @moduledoc """
  A running, chat-style record of what each issue's agents have done: their
  messages, the commands and tools they ran, the files they edited, messages
  people sent them from the dashboard, and the stage moves Symphony made.

  Entries are kept in memory per issue identifier (the newest #{400}), fed from
  the agent runner as Codex, Claude Code, and OpenCode events arrive. Streaming
  deltas are skipped; each entry is a finished message or action. An action
  that has a start and an end (a command, a tool call) is one entry that is
  updated in place when it finishes.

  Every entry has the same keys (see `t:entry/0`); `kind`, `text`, and `at` are
  always set, the rest are `nil` when they don't apply. `text` is a plain-text
  rendering of the entry for simple views. Kinds:

    * `"user"` - a dashboard message to the agent: `author`, `status`
      (`"queued"` / `"delivered"`), `delivery` (`"steered"` / `"next_turn"`),
      `message_id`.
    * `"agent"` - an agent message (markdown in `text`).
    * `"thinking"` - reasoning the agent shared.
    * `"command"` - a shell command: `command`, `body` (output, its end kept),
      `exit_code`, `duration_ms`, `status` (`"running"`, `"completed"`,
      `"failed"`, `"declined"`), `title` (`"Ran <command>"`).
    * `"edit"` - file edits: `files` (`[%{path, kind, additions, deletions,
      diff}]`, unknown values `nil`), `title` (`"Edited 2 files"`).
    * `"tool"` - any other tool call: `tool`, `title`, `body` (input and
      output), `status`, `duration_ms`.
    * `"turn"` - an agent turn starting: `turn`, `stage`, `title`
      (`"Turn 2 · implement"`).
    * `"symphony"` - a line from Symphony itself; `"error"` - a failed turn.

  Older builds wrote commands, edits and tools as kind `"tool"` with only
  `text`; those still read fine.
  """

  use GenServer
  require Logger

  @table :symphony_transcripts
  @max_entries 400
  @max_text 8_000
  @max_body 6_000
  @max_diff 4_000
  @max_files 50
  @text_output_tail 1_500

  @fields [
    :id,
    :at,
    :kind,
    :text,
    :title,
    :body,
    :command,
    :exit_code,
    :duration_ms,
    :files,
    :author,
    :status,
    :delivery,
    :message_id,
    :tool,
    :backend,
    :turn,
    :stage,
    :ref
  ]

  @type file_change :: %{
          path: String.t(),
          kind: String.t() | nil,
          additions: non_neg_integer() | nil,
          deletions: non_neg_integer() | nil,
          diff: String.t() | nil
        }

  @type entry :: %{
          id: String.t(),
          at: DateTime.t(),
          kind: String.t(),
          text: String.t(),
          title: String.t() | nil,
          body: String.t() | nil,
          command: String.t() | nil,
          exit_code: integer() | nil,
          duration_ms: non_neg_integer() | nil,
          files: [file_change()] | nil,
          author: String.t() | nil,
          status: String.t() | nil,
          delivery: String.t() | nil,
          message_id: String.t() | nil,
          tool: String.t() | nil,
          backend: String.t() | nil,
          turn: pos_integer() | nil,
          stage: String.t() | nil,
          ref: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:write, identifier, changes}, _from, state) do
    existing =
      case :ets.lookup(@table, identifier) do
        [{_, list}] -> list
        [] -> []
      end

    :ets.insert(@table, {identifier, Enum.reduce(changes, existing, &apply_change/2) |> Enum.take(@max_entries)})
    {:reply, :ok, state}
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
  person would want to read. `opts`: `backend` (`"codex"`, `"claude"`,
  `"opencode"`), stored on the entries.
  """
  @spec record(String.t() | nil, map(), keyword()) :: :ok
  def record(identifier, update, opts \\ [])

  def record(identifier, update, opts) when is_binary(identifier) and is_map(update) do
    case changes(update) do
      [] -> :ok
      changes -> write(identifier, Enum.map(changes, &put_backend(&1, Keyword.get(opts, :backend))))
    end
  end

  def record(_identifier, _update, _opts), do: :ok

  @doc """
  Records a line from Symphony itself (a stage starting, a move, a rejection).
  """
  @spec note(String.t() | nil, String.t()) :: :ok
  def note(identifier, text) when is_binary(identifier) and is_binary(text),
    do: write(identifier, [{:add, %{kind: "symphony", text: text}}])

  def note(_identifier, _text), do: :ok

  @doc """
  Marks the start of an agent turn: `%{turn: 2, stage: "implement", backend: "codex"}`.
  """
  @spec turn_started(String.t() | nil, map()) :: :ok
  def turn_started(identifier, %{turn: turn} = info) when is_binary(identifier) and is_integer(turn) do
    stage = Map.get(info, :stage)
    title = Enum.join(["Turn #{turn}" | List.wrap(stage)], " · ")
    write(identifier, [{:add, %{kind: "turn", turn: turn, stage: stage, backend: Map.get(info, :backend), title: title}}])
  end

  def turn_started(_identifier, _info), do: :ok

  @doc """
  Records a dashboard message sent to the agent (an `SymphonyElixir.AgentInbox` message).
  """
  @spec user_message(String.t() | nil, map()) :: :ok
  def user_message(identifier, %{id: id, text: text} = message) when is_binary(identifier) do
    entry = %{
      kind: "user",
      text: text,
      author: message[:author],
      status: message[:status],
      delivery: message[:delivery],
      message_id: id,
      ref: "inbox:" <> id
    }

    write(identifier, [{:add, entry}])
  end

  def user_message(_identifier, _message), do: :ok

  @doc """
  Updates a dashboard message's entry once it reached the agent.
  """
  @spec message_delivered(String.t() | nil, map()) :: :ok
  def message_delivered(identifier, %{id: id} = message) when is_binary(identifier) do
    write(identifier, [{:update, "inbox:" <> id, %{status: message[:status], delivery: message[:delivery]}}])
  end

  def message_delivered(_identifier, _message), do: :ok

  @doc false
  @spec reset() :: :ok
  def reset do
    if ready?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  defp write(identifier, changes) do
    if ready?() do
      try do
        GenServer.call(__MODULE__, {:write, identifier, changes})
      catch
        :exit, reason -> Logger.debug("Transcript write skipped reason=#{inspect(reason, limit: 5)}")
      end
    end

    :ok
  end

  defp ready?, do: :ets.whereis(@table) != :undefined

  defp put_backend({:add, entry}, backend), do: {:add, Map.put_new(entry, :backend, backend)}
  defp put_backend(change, _backend), do: change

  # --------------------------------------------------------------- storage

  # {:add, entry}: new entry, or replaces the fields of the one with the same ref.
  # {:update, ref, fields}: changes an existing entry; ignored when there is none.
  # {:result, ref, %{output, error?}}: a tool result for a tool_use seen earlier.
  defp apply_change({:add, entry}, list) do
    case entry[:ref] && Enum.find_index(list, &(&1.ref == entry.ref)) do
      nil -> [finalize(new_entry(entry)) | list]
      index -> List.update_at(list, index, &finalize(Map.merge(&1, Map.take(entry, @fields -- [:id, :at]))))
    end
  end

  defp apply_change({:update, ref, fields}, list) do
    case Enum.find_index(list, &(&1.ref == ref)) do
      nil -> list
      index -> List.update_at(list, index, &finalize(Map.merge(&1, reject_nil(fields))))
    end
  end

  defp apply_change({:result, ref, result}, list) do
    case Enum.find_index(list, &(&1.ref == ref)) do
      nil -> [finalize(new_entry(%{kind: "tool", title: "Tool result", body: result.output, ref: ref, status: status(result)})) | list]
      index -> List.update_at(list, index, &finalize(merge_result(&1, result)))
    end
  end

  defp new_entry(fields) do
    @fields
    |> Map.new(&{&1, nil})
    |> Map.merge(%{id: "t_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36), at: DateTime.utc_now()})
    |> Map.merge(Map.take(fields, @fields))
  end

  defp merge_result(%{kind: "command"} = entry, %{output: output, error?: error?} = result) do
    exit_code = entry.exit_code || exit_code_from(output, error?)
    %{entry | body: cap_body(strip_exit_line(output)), status: status(result), exit_code: exit_code}
  end

  defp merge_result(entry, %{output: output} = result) do
    body = [entry.body, output] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n")
    %{entry | body: cap_body(body), status: status(result)}
  end

  defp status(%{error?: true}), do: "failed"
  defp status(_result), do: "completed"

  # Claude Code reports a failing Bash command as an error whose text starts "Exit code N".
  defp exit_code_from(output, true) do
    case Regex.run(~r/\AExit code (-?\d+)/, output || "") do
      [_, code] -> String.to_integer(code)
      _ -> nil
    end
  end

  defp exit_code_from(_output, _error?), do: 0

  defp strip_exit_line(output), do: Regex.replace(~r/\AExit code -?\d+\n?/, output || "", "")

  defp finalize(entry) do
    text = entry_text(entry) || ""
    %{entry | text: String.slice(String.trim(text), 0, @max_text)}
  end

  defp entry_text(%{kind: "command"} = entry) do
    exit = if is_integer(entry.exit_code), do: " (exit #{entry.exit_code})", else: ""
    output = (entry.body || "") |> String.trim() |> tail_cap(@text_output_tail)
    "$ " <> (entry.command || "") <> exit <> if(output == "", do: "", else: "\n" <> output)
  end

  defp entry_text(%{kind: "edit", files: files} = entry) when is_list(files) and files != [] do
    "Edited " <> Enum.map_join(files, ", ", & &1.path) <> if(entry.status == "failed", do: " (failed)", else: "")
  end

  defp entry_text(%{kind: kind, title: title}) when kind in ["edit", "turn"], do: title

  defp entry_text(%{kind: "tool", title: title}) when is_binary(title), do: title
  defp entry_text(%{text: text}), do: text

  # --------------------------------------------------------------- events

  @doc false
  @spec changes(map()) :: [tuple()]
  def changes(update) do
    case payload(update) do
      %{"method" => "item/completed", "params" => %{"item" => item}} -> codex_item(item) |> List.wrap()
      %{"method" => "item/started", "params" => %{"item" => %{"type" => "commandExecution"} = item}} -> [codex_item(item)]
      %{"method" => "turn/failed"} = p -> [{:add, %{kind: "error", text: "Turn failed: " <> inspect(get_in(p, ["params", "error"]))}}]
      %{"payload" => %{"type" => "message.part.updated", "properties" => %{"part" => part}}} -> part(part) |> List.wrap()
      _ -> []
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

  # Codex items. Commands also arrive when they start, as "running".
  defp codex_item(%{"type" => "agentMessage", "text" => text}) when is_binary(text) and text != "",
    do: {:add, %{kind: "agent", text: text}}

  defp codex_item(%{"type" => "commandExecution"} = item) do
    command = item["command"] |> List.wrap() |> Enum.join(" ")

    {:add,
     %{
       kind: "command",
       command: command,
       title: "Ran " <> one_line(command),
       body: item["aggregatedOutput"] |> to_string() |> cap_body(),
       exit_code: integer(item["exitCode"]),
       duration_ms: integer(item["durationMs"]),
       status: codex_status(item["status"]) || if(is_integer(item["exitCode"]), do: "completed"),
       ref: codex_ref(item)
     }}
  end

  defp codex_item(%{"type" => "fileChange", "changes" => changes} = item) when is_list(changes) do
    files = changes |> Enum.take(@max_files) |> Enum.map(&codex_file/1)

    {:add,
     %{
       kind: "edit",
       files: files,
       title: edited_title(files),
       status: codex_status(item["status"]),
       ref: codex_ref(item)
     }}
  end

  defp codex_item(%{"type" => "reasoning"} = item) do
    summary = item["summary"] |> List.wrap() |> Enum.map_join("\n", &reasoning_text/1) |> String.trim()
    text = if summary == "", do: item["content"] |> List.wrap() |> Enum.map_join("\n", &reasoning_text/1) |> String.trim(), else: summary
    if text == "", do: nil, else: {:add, %{kind: "thinking", text: text}}
  end

  defp codex_item(%{"type" => "mcpToolCall"} = item) do
    tool = "#{item["server"]}/#{item["tool"]}"
    output = if is_map(item["error"]), do: "Error: #{item["error"]["message"]}", else: content_text(get_in(item, ["result", "content"]))

    {:add,
     %{
       kind: "tool",
       tool: tool,
       title: tool,
       body: tool_body(item["arguments"], output),
       status: codex_status(item["status"]),
       duration_ms: integer(item["durationMs"]),
       ref: codex_ref(item)
     }}
  end

  defp codex_item(%{"type" => "dynamicToolCall"} = item) do
    tool = item["tool"] || item["name"] || "tool"

    status =
      case item["success"] do
        true -> "completed"
        false -> "failed"
        _ -> codex_status(item["status"])
      end

    {:add,
     %{
       kind: "tool",
       tool: tool,
       title: tool,
       body: tool_body(item["arguments"], content_text(item["contentItems"])),
       status: status,
       duration_ms: integer(item["durationMs"]),
       ref: codex_ref(item)
     }}
  end

  defp codex_item(%{"type" => "webSearch"} = item),
    do: {:add, %{kind: "tool", tool: "web_search", title: "Searched the web: #{item["query"]}", ref: codex_ref(item)}}

  defp codex_item(_item), do: nil

  defp codex_ref(%{"id" => id}) when is_binary(id), do: "codex:" <> id
  defp codex_ref(_item), do: nil

  defp codex_status("inProgress"), do: "running"
  defp codex_status(status) when status in ["completed", "failed", "declined"], do: status
  defp codex_status(_status), do: nil

  defp codex_file(%{} = change) do
    kind =
      case change["kind"] do
        %{"type" => type} when is_binary(type) -> type
        type when is_binary(type) -> type
        _ -> nil
      end

    diff = if is_binary(change["diff"]), do: change["diff"]
    {additions, deletions} = diff_counts(diff, kind)

    %{
      path: change["path"] || "a file",
      kind: kind,
      additions: additions,
      deletions: deletions,
      diff: if(diff, do: tail_cap(diff, @max_diff))
    }
  end

  defp codex_file(_change), do: %{path: "a file", kind: nil, additions: nil, deletions: nil, diff: nil}

  # A unified diff counts +/- lines; an added or deleted file's "diff" may be its content.
  defp diff_counts(nil, _kind), do: {nil, nil}

  defp diff_counts(diff, kind) do
    lines = String.split(diff, "\n", trim: true)

    if String.contains?(diff, "@@") or kind not in ["add", "delete"] do
      {Enum.count(lines, &(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++"))), Enum.count(lines, &(String.starts_with?(&1, "-") and not String.starts_with?(&1, "---")))}
    else
      if kind == "add", do: {length(lines), 0}, else: {0, length(lines)}
    end
  end

  defp reasoning_text(%{"text" => text}) when is_binary(text), do: text
  defp reasoning_text(text) when is_binary(text), do: text
  defp reasoning_text(_part), do: ""

  defp content_text(items) when is_list(items) do
    items |> Enum.map(&reasoning_text/1) |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
  end

  defp content_text(text) when is_binary(text), do: text
  defp content_text(_items), do: ""

  # Claude Code and OpenCode message parts. OpenCode updates a part in place
  # as it streams, so parts with an id replace their earlier entry.
  defp part(%{"type" => "text", "text" => text} = part) when is_binary(text) and text != "",
    do: {:add, %{kind: "agent", text: text, ref: part_ref(part)}}

  defp part(%{"type" => "reasoning", "text" => text} = part) when is_binary(text) and text != "",
    do: {:add, %{kind: "thinking", text: text, ref: part_ref(part)}}

  defp part(%{"type" => "tool", "tool" => tool} = part) when is_binary(tool) do
    state = if is_map(part["state"]), do: part["state"], else: %{}
    input = tool_input(part, state)
    status = opencode_status(state["status"])
    output = if is_binary(state["output"]), do: state["output"], else: state["error"]

    fields =
      tool
      |> tool_fields(input)
      |> Map.merge(%{tool: tool, status: status, ref: part_ref(part)})
      |> put_tool_output(output, state)

    {:add, fields}
  end

  defp part(%{"type" => "tool_result", "callID" => id} = part) when is_binary(id) do
    {:result, "part:" <> id, %{output: content_text(part["output"]), error?: part["is_error"] == true}}
  end

  defp part(_part), do: nil

  defp part_ref(%{"callID" => id}) when is_binary(id), do: "part:" <> id
  defp part_ref(%{"id" => id}) when is_binary(id), do: "part:" <> id
  defp part_ref(_part), do: nil

  defp opencode_status(status) when status in ["running", "pending"], do: "running"
  defp opencode_status("completed"), do: "completed"
  defp opencode_status("error"), do: "failed"
  defp opencode_status(_status), do: nil

  defp tool_input(part, state) do
    cond do
      is_map(part["args"]) -> part["args"]
      is_map(state["input"]) -> state["input"]
      is_binary(part["input"]) -> decode(part["input"]) || part["input"]
      is_binary(state["input"]) -> decode(state["input"]) || state["input"]
      true -> %{}
    end
  end

  defp put_tool_output(fields, output, _state) when output in [nil, ""], do: fields

  defp put_tool_output(%{kind: "command"} = fields, output, state) do
    exit_code = integer(get_in(state, ["metadata", "exit"]))
    %{fields | body: cap_body(to_string(output))} |> Map.put(:exit_code, exit_code)
  end

  defp put_tool_output(fields, output, _state) do
    Map.put(fields, :body, cap_body(Enum.join(Enum.reject([fields[:body], to_string(output)], &(&1 in [nil, ""])), "\n\n")))
  end

  defp tool_fields(tool, input) do
    name = tool |> String.downcase() |> String.replace(~r/[^a-z_]/, "")
    input_map = if is_map(input), do: input, else: %{}

    cond do
      name == "bash" ->
        command = to_string(input_map["command"] || "")
        %{kind: "command", command: command, title: "Ran " <> one_line(command), body: nil}

      name in ["edit", "multiedit", "write", "notebookedit", "patch", "apply_patch"] ->
        files = edit_files(name, input_map, input)
        %{kind: "edit", files: files, title: edited_title(files)}

      true ->
        %{kind: "tool", title: tool_title(name, tool, input_map), body: tool_body(input, nil)}
    end
  end

  defp edit_files(name, input, raw) when name in ["patch", "apply_patch"] do
    text = input["patchText"] || input["patch"] || input["input"] || if(is_binary(raw), do: raw, else: "")

    for [_, action, path] <- Regex.scan(~r/^\*\*\* (Add|Update|Delete) File: (.+)$/m, to_string(text)) do
      %{path: String.trim(path), kind: String.downcase(action), additions: nil, deletions: nil, diff: nil}
    end
  end

  defp edit_files(name, input, _raw) do
    path = input["file_path"] || input["filePath"] || input["notebook_path"] || input["path"] || "a file"
    {additions, deletions, kind} = edit_counts(name, input)
    [%{path: to_string(path), kind: kind, additions: additions, deletions: deletions, diff: nil}]
  end

  defp edit_counts("write", input), do: {count_lines(input["content"]), nil, "write"}

  defp edit_counts("multiedit", input) do
    edits = if is_list(input["edits"]), do: input["edits"], else: []
    {sum_lines(edits, ["new_string", "newString"]), sum_lines(edits, ["old_string", "oldString"]), "update"}
  end

  defp edit_counts(_name, input) do
    new_text = input["new_string"] || input["newString"] || input["new_source"]
    {count_lines(new_text), count_lines(input["old_string"] || input["oldString"]), "update"}
  end

  defp sum_lines(edits, keys) do
    edits
    |> Enum.map(fn edit -> if is_map(edit), do: count_lines(Enum.find_value(keys, &edit[&1])), else: nil end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      counts -> Enum.sum(counts)
    end
  end

  defp count_lines(text) when is_binary(text) and text != "", do: text |> String.trim_trailing("\n") |> String.split("\n") |> length()
  defp count_lines(_text), do: nil

  defp tool_title("read", _tool, input), do: "Read " <> to_string(input["file_path"] || input["filePath"] || input["path"] || "a file")
  defp tool_title("grep", _tool, input), do: "Searched for " <> to_string(input["pattern"] || "")
  defp tool_title("glob", _tool, input), do: "Listed files " <> to_string(input["pattern"] || "")
  defp tool_title("ls", _tool, input), do: "Listed " <> to_string(input["path"] || "files")
  defp tool_title("webfetch", _tool, input), do: "Fetched " <> to_string(input["url"] || "a page")
  defp tool_title("websearch", _tool, input), do: "Searched the web: " <> to_string(input["query"] || "")
  defp tool_title(name, _tool, input) when name in ["task", "agent"], do: "Ran an agent: " <> to_string(input["description"] || "")
  defp tool_title(name, _tool, _input) when name in ["todowrite", "todoread"], do: "Updated the todo list"

  defp tool_title(_name, "mcp__" <> rest, _input) do
    case String.split(rest, "__", parts: 2) do
      [server, tool] -> "#{server}/#{tool}"
      _ -> rest
    end
  end

  defp tool_title(_name, tool, _input), do: tool

  defp edited_title([%{path: path}]), do: "Edited " <> path
  defp edited_title(files) when is_list(files) and files != [], do: "Edited #{length(files)} files"
  defp edited_title(_files), do: "Edited files"

  defp tool_body(input, output) do
    input_text =
      case input do
        empty when empty in [nil, "", "{}", %{}] -> nil
        text when is_binary(text) -> text
        other -> Jason.encode!(other, pretty: true)
      end

    case [input_text, output] |> Enum.reject(&(&1 in [nil, ""])) do
      [] -> nil
      parts -> parts |> Enum.join("\n\n") |> cap_body()
    end
  end

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil

  defp one_line(text) do
    line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()
    if String.length(line) > 160, do: String.slice(line, 0, 159) <> "…", else: line
  end

  defp cap_body(nil), do: nil
  defp cap_body(text), do: text |> String.trim_trailing() |> tail_cap(@max_body)

  defp tail_cap(text, max) do
    if String.length(text) > max, do: "…" <> String.slice(text, -max, max), else: text
  end

  defp reject_nil(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
