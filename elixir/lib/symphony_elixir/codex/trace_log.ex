defmodule SymphonyElixir.Codex.TraceLog do
  @moduledoc """
  Emits a compact, ordered Codex run timeline for the local observability stack.

  The dev observability wrapper captures stderr as JSONL and Vector forwards
  those lines into VictoriaLogs. This module keeps the output opt-in through
  `AGENT_OBSERVABILITY=1` so regular Symphony runs are not noisier.
  """

  alias SymphonyElixir.Config

  @context_key {__MODULE__, :context}
  @sequence_key {__MODULE__, :sequence}
  @max_text_chars 4_000
  @truthy_values ~w(1 true TRUE yes YES on ON)

  @type context :: %{
          optional(:issue_id) => String.t() | nil,
          optional(:issue_identifier) => String.t() | nil,
          optional(:session_id) => String.t() | nil,
          optional(:thread_id) => String.t() | nil,
          optional(:turn_id) => String.t() | nil,
          optional(:turn_number) => pos_integer() | nil
        }

  @spec put_context(context()) :: :ok
  def put_context(context) when is_map(context) do
    Process.put(@context_key, compact(context))
    Process.put(@sequence_key, 0)
    :ok
  end

  @spec clear_context() :: :ok
  def clear_context do
    Process.delete(@context_key)
    Process.delete(@sequence_key)
    :ok
  end

  @spec context_metadata() :: map()
  def context_metadata do
    Process.get(@context_key, %{})
  end

  @spec with_sequence(map()) :: map()
  def with_sequence(message) when is_map(message) do
    Map.put(message, :trace_sequence, next_sequence())
  end

  @spec emit(map()) :: :ok
  def emit(message) when is_map(message) do
    if enabled?() do
      case trace_event(message) do
        nil -> :ok
        event -> IO.puts(:stderr, Jason.encode!(event))
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp next_sequence do
    sequence = Process.get(@sequence_key, 0) + 1
    Process.put(@sequence_key, sequence)
    sequence
  end

  defp enabled? do
    System.get_env("AGENT_OBSERVABILITY") in @truthy_values or
      System.get_env("SYMPHONY_CODEX_TRACE_JSONL") in @truthy_values
  end

  defp trace_event(message) do
    payload = unwrap_payload(message)
    method = value(payload, ["method", :method])
    event = value(message, [:event, "event"])

    case classify(event, method, payload, message) do
      nil ->
        nil

      attrs ->
        message
        |> base_event(method)
        |> Map.merge(attrs)
        |> compact()
    end
  end

  defp base_event(message, method) do
    context = context_metadata()

    %{
      "timestamp" => iso8601(value(message, [:timestamp, "timestamp"]) || DateTime.utc_now()),
      "level" => "info",
      "dev_env" => dev_env(),
      "service" => "symphony",
      "event" => "codex_trace",
      "backend" => "codex",
      "method" => method,
      "sequence" => value(message, [:trace_sequence, "trace_sequence"]),
      "step" => value(message, [:turn_number, "turn_number"]) || Map.get(context, :turn_number),
      "session_id" => value(message, [:session_id, "session_id"]) || Map.get(context, :session_id),
      "thread_id" => value(message, [:thread_id, "thread_id"]) || Map.get(context, :thread_id),
      "turn_id" => value(message, [:turn_id, "turn_id"]) || Map.get(context, :turn_id),
      "issue_id" => value(message, [:issue_id, "issue_id"]) || Map.get(context, :issue_id),
      "issue_identifier" => value(message, [:issue_identifier, "issue_identifier"]) || Map.get(context, :issue_identifier),
      "worker_host" => value(message, [:worker_host, "worker_host"]),
      "codex_app_server_pid" => value(message, [:codex_app_server_pid, "codex_app_server_pid"])
    }
  end

  defp classify(:session_started, _method, _payload, message) do
    %{
      "trace_kind" => "session_started",
      "message" => "#{step_label(message)}: session started"
    }
  end

  defp classify(:turn_completed, _method, payload, message) do
    %{
      "trace_kind" => "turn_completed",
      "message" => "#{step_label(message)}: turn completed",
      "status" => path(payload, ["params", "turn", "status"]) || path(payload, [:params, :turn, :status])
    }
  end

  defp classify(:turn_failed, _method, payload, message) do
    %{
      "trace_kind" => "turn_failed",
      "message" => "#{step_label(message)}: turn failed",
      "error" => path(payload, ["params", "error", "message"]) || path(payload, [:params, :error, :message])
    }
  end

  defp classify(:turn_cancelled, _method, _payload, message) do
    %{
      "trace_kind" => "turn_cancelled",
      "message" => "#{step_label(message)}: turn cancelled"
    }
  end

  defp classify(:turn_ended_with_error, _method, _payload, message) do
    %{
      "trace_kind" => "turn_ended_with_error",
      "message" => "#{step_label(message)}: turn ended with error",
      "error" => inspect(value(message, [:reason, "reason"]), limit: 10, printable_limit: 500)
    }
  end

  defp classify(event, _method, payload, message)
       when event in [:tool_call_completed, :tool_call_failed, :unsupported_tool_call] do
    tool = dynamic_tool_name(payload)
    status = tool_status(event)

    %{
      "trace_kind" => "dynamic_tool_#{status}",
      "message" => "#{step_label(message)}: tool #{tool || "unknown"} #{String.replace(status, "_", " ")}",
      "tool_name" => tool,
      "call_id" => path(payload, ["params", "callId"]) || path(payload, [:params, :callId])
    }
    |> maybe_put_tool_arguments(payload)
  end

  defp classify(:approval_auto_approved, _method, payload, message) do
    %{
      "trace_kind" => "approval_auto_approved",
      "message" => "#{step_label(message)}: approval auto-approved",
      "command" => extract_command(payload),
      "decision" => value(message, [:decision, "decision"])
    }
  end

  defp classify(:tool_input_auto_answered, _method, payload, message) do
    %{
      "trace_kind" => "tool_input_auto_answered",
      "message" => "#{step_label(message)}: tool input auto-answered",
      "question" => path(payload, ["params", "question"]) || path(payload, [:params, :question])
    }
  end

  defp classify(_event, method, payload, message) when is_binary(method) do
    classify_method(method, payload, message)
  end

  defp classify(_event, _method, _payload, _message), do: nil

  defp classify_method(method, _payload, _message)
       when method in ["thread/tokenUsage/updated", "codex/event/token_count"],
       do: nil

  defp classify_method(method, payload, message)
       when method in [
              "item/agentMessage/delta",
              "codex/event/agent_message_delta",
              "codex/event/agent_message_content_delta"
            ] do
    text = extract_text(payload)

    %{
      "trace_kind" => "assistant_text_delta",
      "message" => "#{step_label(message)}: text #{inline_text(text)}",
      "text" => text
    }
  end

  defp classify_method(method, payload, message)
       when method in [
              "item/reasoning/summaryTextDelta",
              "item/reasoning/summaryPartAdded",
              "item/reasoning/textDelta",
              "codex/event/agent_reasoning_delta",
              "codex/event/reasoning_content_delta",
              "codex/event/agent_reasoning"
            ] do
    text = extract_text(payload)

    %{
      "trace_kind" => "reasoning_delta",
      "message" => "#{step_label(message)}: reasoning #{inline_text(text)}",
      "text" => text
    }
  end

  defp classify_method("item/started", payload, message), do: item_lifecycle("item_started", payload, message)
  defp classify_method("item/completed", payload, message), do: item_lifecycle("item_completed", payload, message)
  defp classify_method("codex/event/item_started", payload, message), do: wrapper_item_lifecycle("item_started", payload, message)
  defp classify_method("codex/event/item_completed", payload, message), do: wrapper_item_lifecycle("item_completed", payload, message)

  defp classify_method(method, payload, message)
       when method in ["item/commandExecution/requestApproval", "execCommandApproval"] do
    command = extract_command(payload)

    %{
      "trace_kind" => "command_approval_requested",
      "message" => "#{step_label(message)}: command approval requested #{inline_text(command)}",
      "command" => command
    }
  end

  defp classify_method(method, payload, message)
       when method in ["item/commandExecution/outputDelta", "codex/event/exec_command_output_delta"] do
    text = extract_text(payload)

    %{
      "trace_kind" => "command_output_delta",
      "message" => "#{step_label(message)}: command output #{inline_text(text)}",
      "text" => text
    }
  end

  defp classify_method("codex/event/exec_command_begin", payload, message) do
    command = extract_command(payload)

    %{
      "trace_kind" => "command_started",
      "message" => "#{step_label(message)}: command #{inline_text(command)}",
      "command" => command
    }
  end

  defp classify_method("codex/event/exec_command_end", payload, message) do
    exit_code =
      path(payload, ["params", "msg", "exit_code"]) ||
        path(payload, [:params, :msg, :exit_code]) ||
        path(payload, ["params", "msg", "exitCode"]) ||
        path(payload, [:params, :msg, :exitCode])

    %{
      "trace_kind" => "command_completed",
      "message" => "#{step_label(message)}: command completed#{exit_suffix(exit_code)}",
      "exit_code" => exit_code
    }
  end

  defp classify_method("item/tool/call", payload, message) do
    tool = dynamic_tool_name(payload)

    %{
      "trace_kind" => "dynamic_tool_requested",
      "message" => "#{step_label(message)}: tool #{tool || "unknown"} requested",
      "tool_name" => tool,
      "call_id" => path(payload, ["params", "callId"]) || path(payload, [:params, :callId])
    }
    |> maybe_put_tool_arguments(payload)
  end

  defp classify_method(method, payload, message)
       when method in ["codex/event/mcp_tool_call_begin", "codex/event/mcp_tool_call_end"] do
    tool = dynamic_tool_name(payload)
    kind = if String.ends_with?(method, "_begin"), do: "mcp_tool_started", else: "mcp_tool_completed"

    %{
      "trace_kind" => kind,
      "message" => "#{step_label(message)}: mcp tool #{tool || "unknown"} #{if kind == "mcp_tool_started", do: "started", else: "completed"}",
      "tool_name" => tool
    }
    |> maybe_put_tool_arguments(payload)
  end

  defp classify_method(method, payload, message)
       when method in ["turn/plan/updated", "item/plan/delta"] do
    text = extract_text(payload)

    %{
      "trace_kind" => "plan_update",
      "message" => "#{step_label(message)}: plan #{inline_text(text)}",
      "text" => text
    }
  end

  defp classify_method(method, _payload, message) do
    %{
      "trace_kind" => "codex_event",
      "message" => "#{step_label(message)}: #{method}"
    }
  end

  defp item_lifecycle(kind, payload, message) do
    item = path(payload, ["params", "item"]) || path(payload, [:params, :item]) || %{}
    item_type = value(item, ["type", :type])
    item_id = value(item, ["id", :id])
    status = value(item, ["status", :status])

    %{
      "trace_kind" => kind,
      "message" => "#{step_label(message)}: #{String.replace(kind, "_", " ")} #{item_type || "item"}",
      "item_id" => item_id,
      "item_type" => item_type,
      "status" => status
    }
  end

  defp wrapper_item_lifecycle(kind, payload, message) do
    msg = path(payload, ["params", "msg"]) || path(payload, [:params, :msg]) || %{}
    item_type = value(msg, ["type", :type])
    item_id = value(msg, ["id", :id])
    status = value(msg, ["status", :status])

    %{
      "trace_kind" => kind,
      "message" => "#{step_label(message)}: #{String.replace(kind, "_", " ")} #{item_type || "item"}",
      "item_id" => item_id,
      "item_type" => item_type,
      "status" => status
    }
  end

  defp tool_status(:tool_call_completed), do: "completed"
  defp tool_status(:tool_call_failed), do: "failed"
  defp tool_status(:unsupported_tool_call), do: "unsupported"

  defp maybe_put_tool_arguments(event, payload) do
    if log_tool_details?() do
      arguments =
        path(payload, ["params", "arguments"]) ||
          path(payload, [:params, :arguments]) ||
          path(payload, ["params", "msg", "arguments"]) ||
          path(payload, [:params, :msg, :arguments])

      Map.put(event, "tool_arguments", arguments)
    else
      event
    end
  end

  defp log_tool_details? do
    Config.settings!().telemetry.log_tool_details
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp dynamic_tool_name(payload) do
    extract_first_path(payload, [
      ["params", "tool"],
      ["params", "name"],
      [:params, :tool],
      [:params, :name],
      ["params", "msg", "tool"],
      ["params", "msg", "name"],
      [:params, :msg, :tool],
      [:params, :msg, :name],
      ["params", "msg", "server"],
      [:params, :msg, :server]
    ])
  end

  defp extract_command(payload) do
    command =
      extract_first_path(payload, [
        ["params", "parsedCmd"],
        [:params, :parsedCmd],
        ["params", "command"],
        [:params, :command],
        ["params", "cmd"],
        [:params, :cmd],
        ["params", "msg", "command"],
        [:params, :msg, :command],
        ["params", "msg", "parsed_cmd"],
        [:params, :msg, :parsed_cmd],
        ["params", "msg", "parsedCmd"],
        [:params, :msg, :parsedCmd]
      ])

    normalize_command(command)
  end

  defp normalize_command(command) when is_binary(command), do: command
  defp normalize_command(command) when is_list(command), do: Enum.map_join(command, " ", &to_string/1)
  defp normalize_command(_command), do: nil

  defp extract_text(payload) do
    payload
    |> extract_first_path([
      ["params", "delta"],
      [:params, :delta],
      ["params", "textDelta"],
      [:params, :textDelta],
      ["params", "summaryText"],
      [:params, :summaryText],
      ["params", "outputDelta"],
      [:params, :outputDelta],
      ["params", "msg", "payload", "delta"],
      [:params, :msg, :payload, :delta],
      ["params", "msg", "payload", "text"],
      [:params, :msg, :payload, :text],
      ["params", "msg", "payload", "summaryText"],
      [:params, :msg, :payload, :summaryText],
      ["params", "msg", "delta"],
      [:params, :msg, :delta],
      ["params", "msg", "text"],
      [:params, :msg, :text],
      ["params", "msg", "output"],
      [:params, :msg, :output]
    ])
    |> normalize_text()
  end

  defp normalize_text(text) when is_binary(text), do: truncate_text(text)
  defp normalize_text(nil), do: nil
  defp normalize_text(text), do: text |> inspect(limit: 10, printable_limit: @max_text_chars) |> truncate_text()

  defp truncate_text(text) when is_binary(text) do
    if String.length(text) > @max_text_chars do
      String.slice(text, 0, @max_text_chars) <> "...[truncated]"
    else
      text
    end
  end

  defp inline_text(nil), do: ""

  defp inline_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_inline()
  end

  defp inline_text(text), do: text |> inspect(limit: 10, printable_limit: 300) |> truncate_inline()

  defp truncate_inline(text) when is_binary(text) do
    if String.length(text) > 160 do
      String.slice(text, 0, 160) <> "..."
    else
      text
    end
  end

  defp step_label(message) do
    case value(message, [:turn_number, "turn_number"]) || Map.get(context_metadata(), :turn_number) do
      number when is_integer(number) -> "step #{number}"
      number when is_binary(number) and number != "" -> "step #{number}"
      _ -> "step"
    end
  end

  defp exit_suffix(code) when is_integer(code), do: " (exit #{code})"
  defp exit_suffix(_code), do: ""

  defp unwrap_payload(message) do
    case value(message, [:payload, "payload"]) do
      payload when is_map(payload) -> payload
      _ -> message
    end
  end

  defp extract_first_path(payload, paths) do
    Enum.find_value(paths, &path(payload, &1))
  end

  defp path(payload, keys) when is_map(payload) and is_list(keys) do
    Enum.reduce_while(keys, payload, &path_step/2)
  end

  defp path(_payload, _keys), do: nil

  defp path_step(key, map) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:cont, value}
      :error -> {:halt, nil}
    end
  end

  defp path_step(_key, _value), do: {:halt, nil}

  defp value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp value(_map, _keys), do: nil

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp dev_env do
    System.get_env("DEV_ID") || System.get_env("USER") || "local"
  end

  defp compact(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {_key, ""}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
