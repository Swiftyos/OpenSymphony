defmodule SymphonyElixir.ClaudeCode.AppServer do
  @moduledoc """
  Minimal client for Claude Code headless streaming mode over stdio.
  """

  require Logger

  alias SymphonyElixir.ClaudeCode.Tooling
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @poll_interval_ms 250
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          port: port(),
          metadata: map(),
          session_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          permission_mode: String.t(),
          model: String.t() | nil,
          turn_timeout_ms: pos_integer(),
          read_timeout_ms: pos_integer(),
          stall_timeout_ms: non_neg_integer()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    settings = Config.settings!().claude
    session_id = Ecto.UUID.generate()

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host, session_id, settings) do
      {:ok,
       %{
         port: port,
         metadata: port_metadata(port, worker_host),
         session_id: session_id,
         workspace: expanded_workspace,
         worker_host: worker_host,
         permission_mode: settings.permission_mode,
         model: settings.model,
         turn_timeout_ms: settings.turn_timeout_ms,
         read_timeout_ms: settings.read_timeout_ms,
         stall_timeout_ms: settings.stall_timeout_ms
       }}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    emit_message(
      on_message,
      :turn_started,
      %{
        session_id: session.session_id,
        title: issue_title(issue)
      },
      session.metadata
    )

    started_at_ms = System.monotonic_time(:millisecond)

    with :ok <- send_turn_input(session.port, prompt),
         {:ok, response} <- await_turn_result(session, on_message, started_at_ms, nil, nil, "") do
      usage = result_usage(response)

      emit_message(
        on_message,
        :turn_completed,
        %{
          session_id: session.session_id,
          payload: response,
          usage: usage
        },
        session.metadata
      )

      {:ok,
       %{
         result: response,
         session_id: session.session_id,
         thread_id: session.session_id,
         turn_id: result_turn_id(response)
       }}
    else
      {:error, reason} ->
        emit_message(
          on_message,
          :turn_ended_with_error,
          %{
            session_id: session.session_id,
            reason: reason
          },
          session.metadata
        )

        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil, session_id, settings) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      {:ok,
       Port.open(
         {:spawn_executable, String.to_charlist(executable)},
         [
           :binary,
           :exit_status,
           :stderr_to_stdout,
           args: [~c"-lc", String.to_charlist(launch_command(session_id, settings))],
           env: port_environment(),
           cd: String.to_charlist(workspace),
           line: @port_line_bytes
         ]
       )}
    end
  end

  defp start_port(workspace, worker_host, session_id, settings) when is_binary(worker_host) do
    SSH.start_port(worker_host, remote_launch_command(workspace, session_id, settings), line: @port_line_bytes)
  end

  defp launch_command(session_id, settings) do
    [
      settings.command,
      "-p",
      "--output-format",
      "stream-json",
      "--input-format",
      "stream-json",
      "--verbose",
      "--strict-mcp-config",
      "--mcp-config",
      shell_escape(Tooling.mcp_config_relative_path()),
      "--permission-mode",
      shell_escape(settings.permission_mode),
      "--session-id",
      shell_escape(session_id)
    ]
    |> maybe_append_model(settings.model)
    |> Enum.join(" ")
  end

  defp maybe_append_model(parts, model) when is_binary(model) and model != "" do
    parts ++ ["--model", shell_escape(model)]
  end

  defp maybe_append_model(parts, _model), do: parts

  defp remote_launch_command(workspace, session_id, settings) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      remote_environment_exports(),
      "exec #{launch_command(session_id, settings)}"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" && ")
  end

  defp remote_environment_exports do
    Config.settings!().tracker
    |> tracker_env_pairs()
    |> Enum.map(fn {key, value} -> "export #{key}=#{shell_escape(value)}" end)
    |> Enum.join(" && ")
  end

  defp port_environment do
    Config.settings!().tracker
    |> tracker_env_pairs()
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp tracker_env_pairs(tracker) do
    []
    |> maybe_put_env("SYMPHONY_LINEAR_API_KEY", tracker.kind == "linear" && tracker.api_key)
    |> maybe_put_env("SYMPHONY_LINEAR_ENDPOINT", tracker.kind == "linear" && tracker.endpoint)
  end

  defp maybe_put_env(entries, _key, nil), do: entries
  defp maybe_put_env(entries, _key, false), do: entries
  defp maybe_put_env(entries, key, value), do: [{key, to_string(value)} | entries]

  defp send_turn_input(port, prompt) when is_port(port) and is_binary(prompt) do
    payload =
      Jason.encode!(%{
        "type" => "user",
        "message" => %{
          "role" => "user",
          "content" => prompt
        }
      }) <> "\n"

    try do
      case :erlang.port_info(port) do
        :undefined ->
          {:error, :port_closed}

        _ ->
          true = Port.command(port, payload)
          :ok
      end
    rescue
      ArgumentError ->
        {:error, :port_closed}
    end
  end

  defp await_turn_result(
         session,
         on_message,
         started_at_ms,
         first_activity_ms,
         last_activity_ms,
         pending_line
       ) do
    receive do
      {port, {:data, {:eol, chunk}}} when port == session.port ->
        line = pending_line <> IO.chardata_to_string(chunk)

        case handle_stream_line(line, session, on_message) do
          {:continue, activity?} ->
            now_ms = System.monotonic_time(:millisecond)

            await_turn_result(
              session,
              on_message,
              started_at_ms,
              first_activity_ms || if(activity?, do: now_ms, else: nil),
              if(activity?, do: now_ms, else: last_activity_ms),
              ""
            )

          {:done, response} ->
            {:ok, response}

          {:error, reason} ->
            {:error, reason}
        end

      {port, {:data, {:noeol, chunk}}} when port == session.port ->
        await_turn_result(
          session,
          on_message,
          started_at_ms,
          first_activity_ms,
          last_activity_ms,
          pending_line <> IO.chardata_to_string(chunk)
        )

      {port, {:exit_status, status}} when port == session.port ->
        {:error, {:port_exit, status}}
    after
      @poll_interval_ms ->
        now_ms = System.monotonic_time(:millisecond)

        cond do
          session.turn_timeout_ms > 0 and now_ms - started_at_ms > session.turn_timeout_ms ->
            stop_port(session.port)
            {:error, :turn_timeout}

          session.read_timeout_ms > 0 and is_nil(first_activity_ms) and
              now_ms - started_at_ms > session.read_timeout_ms ->
            stop_port(session.port)
            {:error, :turn_start_timeout}

          session.stall_timeout_ms > 0 and is_integer(last_activity_ms) and
              now_ms - last_activity_ms > session.stall_timeout_ms ->
            stop_port(session.port)
            {:error, :stall_timeout}

          true ->
            await_turn_result(
              session,
              on_message,
              started_at_ms,
              first_activity_ms,
              last_activity_ms,
              pending_line
            )
        end
    end
  end

  defp handle_stream_line(line, session, on_message) when is_binary(line) do
    payload_string = to_string(line)

    case Jason.decode(payload_string) do
      {:ok, %{"type" => "result"} = payload} ->
        if result_success?(payload) do
          {:done, payload}
        else
          {:error, {:claude_result_error, payload}}
        end

      {:ok, %{"type" => "assistant"} = payload} ->
        emit_assistant_updates(on_message, session, payload)
        {:continue, true}

      {:ok, %{"type" => "system", "subtype" => "init"} = payload} ->
        maybe_log_session_mismatch(session.session_id, payload["session_id"])
        {:continue, true}

      {:ok, %{} = _payload} ->
        {:continue, true}

      {:error, _reason} ->
        log_non_json_stream_line(payload_string)
        {:continue, false}
    end
  end

  defp emit_assistant_updates(on_message, session, payload) do
    usage = assistant_usage(payload)

    payload
    |> assistant_content_items()
    |> Enum.map(&assistant_part_payload(&1, usage, session.session_id))
    |> Enum.each(fn part_payload ->
      emit_message(
        on_message,
        "message.part.updated",
        %{
          session_id: session.session_id,
          payload: part_payload,
          usage: usage
        },
        session.metadata
      )
    end)
  end

  defp assistant_content_items(%{"message" => %{"content" => content}}) when is_list(content), do: content
  defp assistant_content_items(%{message: %{content: content}}) when is_list(content), do: content
  defp assistant_content_items(_payload), do: []

  defp assistant_usage(%{"message" => %{"usage" => usage}}) when is_map(usage), do: usage
  defp assistant_usage(%{message: %{usage: usage}}) when is_map(usage), do: usage
  defp assistant_usage(_payload), do: nil

  defp assistant_part_payload(%{"type" => "text", "text" => text}, usage, session_id) when is_binary(text) do
    part_payload(
      %{
        "type" => "text",
        "text" => text
      },
      usage,
      session_id
    )
  end

  defp assistant_part_payload(%{"type" => type, "text" => text}, usage, session_id)
       when type in ["thinking", "reasoning"] and is_binary(text) do
    part_payload(
      %{
        "type" => "reasoning",
        "text" => text
      },
      usage,
      session_id
    )
  end

  defp assistant_part_payload(%{"type" => "tool_use", "name" => name}, usage, session_id)
       when is_binary(name) do
    part_payload(
      %{
        "type" => "tool",
        "tool" => name,
        "state" => %{"status" => "running"}
      },
      usage,
      session_id
    )
  end

  defp assistant_part_payload(part, usage, session_id) do
    part_payload(
      %{
        "type" => "text",
        "text" => Jason.encode!(part)
      },
      usage,
      session_id
    )
  end

  defp part_payload(part, usage, session_id) do
    part =
      part
      |> Map.put("sessionID", session_id)
      |> maybe_put_tokens(usage)

    %{
      "payload" => %{
        "type" => "message.part.updated",
        "properties" => %{
          "part" => part
        }
      }
    }
  end

  defp maybe_put_tokens(part, usage) when is_map(usage), do: Map.put(part, "tokens", usage)
  defp maybe_put_tokens(part, _usage), do: part

  defp result_success?(%{"is_error" => true}), do: false
  defp result_success?(%{"subtype" => "success"}), do: true
  defp result_success?(_payload), do: false

  defp result_usage(%{"usage" => usage}) when is_map(usage), do: usage
  defp result_usage(_payload), do: %{}

  defp result_turn_id(%{"uuid" => uuid}) when is_binary(uuid), do: uuid

  defp result_turn_id(%{"message" => %{"id" => message_id}}) when is_binary(message_id),
    do: message_id

  defp result_turn_id(_payload), do: nil

  defp issue_title(%{identifier: identifier, title: title})
       when is_binary(identifier) and is_binary(title) do
    "#{identifier}: #{title}"
  end

  defp issue_title(_issue), do: "agent turn"

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{agent_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp maybe_log_session_mismatch(expected_session_id, actual_session_id)
       when is_binary(expected_session_id) and is_binary(actual_session_id) and
              expected_session_id != actual_session_id do
    Logger.warning("Claude session ID mismatch expected=#{expected_session_id} actual=#{actual_session_id}")
  end

  defp maybe_log_session_mismatch(_expected_session_id, _actual_session_id), do: :ok

  defp log_non_json_stream_line(text) when is_binary(text) do
    text = text |> String.trim() |> truncate_output()

    if text != "" do
      Logger.debug("Claude Code stream output: #{text}")
    end
  end

  defp truncate_output(text) when byte_size(text) > @max_stream_log_bytes do
    String.slice(text, 0, @max_stream_log_bytes) <> "..."
  end

  defp truncate_output(text), do: text

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, payload, metadata) do
    message =
      metadata
      |> Map.merge(%{
        event: event,
        timestamp: DateTime.utc_now()
      })
      |> Map.merge(payload)

    on_message.(message)
  rescue
    error ->
      Logger.debug("Claude Code on_message callback failed: #{Exception.message(error)}")
      :ok
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok
end
