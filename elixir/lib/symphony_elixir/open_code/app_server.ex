defmodule SymphonyElixir.OpenCode.AppServer do
  @moduledoc """
  Minimal client for `opencode serve` over HTTP and SSE.
  """

  require Logger

  alias SymphonyElixir.{Config, PathSafety}

  @allowed_unattended_permissions MapSet.new([
                                    "read",
                                    "edit",
                                    "glob",
                                    "grep",
                                    "list",
                                    "bash",
                                    "lsp",
                                    "task",
                                    "skill",
                                    "todowrite",
                                    "webfetch",
                                    "websearch",
                                    "codesearch"
                                  ])
  @listening_line_regex ~r/opencode server listening on (?<url>http:\/\/[^\s]+)/
  @poll_interval_ms 250
  @port_line_bytes 1_048_576
  @stream_idle_poll_ms 250
  @post_message_listener_drain_ms 100
  @port_log_preview_bytes 1_000

  @type session :: %{
          port: port(),
          request: Req.Request.t(),
          base_url: String.t(),
          session_id: String.t(),
          metadata: map(),
          workspace: Path.t(),
          agent: String.t(),
          model: String.t() | nil,
          variant: String.t() | nil,
          turn_timeout_ms: pos_integer(),
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
    variant = Keyword.get(opts, :variant)

    with {:ok, settings} <- Config.opencode_runtime_settings(variant: variant),
         {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host, settings.command) do
      metadata = port_metadata(port)
      read_timeout_ms = settings.read_timeout_ms

      with {:ok, base_url} <- await_server_url(port, read_timeout_ms, ""),
           request <- build_request(base_url, read_timeout_ms),
           :ok <- await_health(request, read_timeout_ms),
           {:ok, session_id} <- create_session(request, expanded_workspace) do
        {:ok,
         %{
           port: port,
           request: request,
           base_url: base_url,
           session_id: session_id,
           metadata: metadata,
           workspace: expanded_workspace,
           agent: settings.agent,
           model: settings.model,
           variant: settings.variant,
           turn_timeout_ms: settings.turn_timeout_ms,
           stall_timeout_ms: settings.stall_timeout_ms
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_ref = make_ref()
    owner = self()

    emit_message(
      on_message,
      :turn_started,
      %{
        session_id: session.session_id,
        title: issue_title(issue)
      },
      session.metadata
    )

    listener_task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        stream_session_events(session, turn_ref, owner, on_message)
      end)

    message_task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        post_turn_message(session, prompt, session)
      end)

    started_at_ms = System.monotonic_time(:millisecond)

    result =
      await_turn_result(
        session,
        turn_ref,
        message_task,
        listener_task,
        started_at_ms,
        started_at_ms,
        session.turn_timeout_ms,
        session.stall_timeout_ms
      )

    stop_async_task(listener_task)
    stop_async_task(message_task)

    case result do
      {:ok, %{} = response} ->
        usage = message_response_token_usage(response)

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
           turn_id: Map.get(response, "info", %{}) |> Map.get("id")
         }}

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

  defp validate_workspace_cwd(_workspace, worker_host) when is_binary(worker_host) do
    {:error, {:opencode_local_only, worker_host}}
  end

  defp start_port(workspace, nil, command) do
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
           args: [~c"-lc", String.to_charlist(command)],
           env: port_environment(),
           cd: String.to_charlist(workspace),
           line: @port_line_bytes
         ]
       )}
    end
  end

  defp start_port(_workspace, worker_host, _command) when is_binary(worker_host) do
    {:error, {:opencode_local_only, worker_host}}
  end

  defp port_environment do
    tracker = Config.settings!().tracker

    []
    |> maybe_put_env("SYMPHONY_LINEAR_API_KEY", tracker.kind == "linear" && tracker.api_key)
    |> maybe_put_env("SYMPHONY_LINEAR_ENDPOINT", tracker.kind == "linear" && tracker.endpoint)
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(to_string(value))}
    end)
  end

  defp maybe_put_env(entries, _key, nil), do: entries
  defp maybe_put_env(entries, _key, false), do: entries
  defp maybe_put_env(entries, key, value), do: [{key, value} | entries]

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} ->
        %{agent_server_pid: to_string(os_pid)}

      _ ->
        %{}
    end
  end

  defp await_server_url(port, timeout_ms, pending_line) when is_port(port) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> IO.chardata_to_string(chunk)

        case parse_listening_url(complete_line) do
          {:ok, url} ->
            {:ok, url}

          :nomatch ->
            log_port_output("server startup", complete_line)
            await_server_url(port, timeout_ms, "")
        end

      {^port, {:data, {:noeol, chunk}}} ->
        await_server_url(port, timeout_ms, pending_line <> IO.chardata_to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :server_start_timeout}
    end
  end

  defp parse_listening_url(line) when is_binary(line) do
    case Regex.named_captures(@listening_line_regex, line) do
      %{"url" => url} -> {:ok, String.trim(url)}
      _ -> :nomatch
    end
  end

  defp build_request(base_url, read_timeout_ms) do
    Req.new(
      base_url: base_url,
      retry: false,
      receive_timeout: read_timeout_ms,
      connect_options: [timeout: read_timeout_ms],
      headers: %{
        "accept" => "application/json"
      }
    )
  end

  defp await_health(request, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_health_until(request, deadline)
  end

  defp await_health_until(request, deadline_ms) do
    case Req.get(request, url: "/global/health") do
      {:ok, %{status: 200, body: %{"healthy" => true}}} ->
        :ok

      {:ok, _response} ->
        sleep_or_timeout(deadline_ms, :healthcheck_timeout, fn ->
          await_health_until(request, deadline_ms)
        end)

      {:error, _reason} ->
        sleep_or_timeout(deadline_ms, :healthcheck_timeout, fn ->
          await_health_until(request, deadline_ms)
        end)
    end
  end

  defp create_session(request, workspace) do
    case Req.post(request, url: "/session", json: %{"title" => Path.basename(workspace)}) do
      {:ok, %{status: status, body: %{"id" => session_id}}} when status in 200..299 and is_binary(session_id) ->
        {:ok, session_id}

      {:ok, %{status: status, body: body}} ->
        {:error, {:session_create_failed, status, body}}

      {:error, reason} ->
        {:error, {:session_create_failed, reason}}
    end
  end

  defp post_turn_message(session, prompt, _settings) do
    payload =
      %{
        "agent" => session.agent,
        "parts" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ]
      }
      |> maybe_put_model(session.model)
      |> maybe_put_variant(session.variant)

    case Req.post(session.request,
           url: "/session/#{session.session_id}/message",
           json: payload
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:message_post_failed, status, body}}

      {:error, reason} ->
        {:error, {:message_post_failed, reason}}
    end
  end

  defp maybe_put_model(payload, model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider_id, model_id] when provider_id != "" and model_id != "" ->
        Map.put(payload, "model", %{"providerID" => provider_id, "modelID" => model_id})

      _ ->
        payload
    end
  end

  defp maybe_put_model(payload, _model), do: payload

  defp maybe_put_variant(payload, variant) when is_binary(variant) and variant != "" do
    Map.put(payload, "variant", variant)
  end

  defp maybe_put_variant(payload, _variant), do: payload

  defp await_turn_result(
         session,
         turn_ref,
         message_task,
         listener_task,
         started_at_ms,
         last_activity_ms,
         turn_timeout_ms,
         stall_timeout_ms
       ) do
    receive do
      {^turn_ref, :activity, activity_ms} ->
        await_turn_result(
          session,
          turn_ref,
          message_task,
          listener_task,
          started_at_ms,
          max(last_activity_ms, activity_ms),
          turn_timeout_ms,
          stall_timeout_ms
        )

      {^turn_ref, :turn_failed, reason} ->
        abort_session(session)
        {:error, reason}

      {^turn_ref, :stream_error, reason} ->
        abort_session(session)
        {:error, reason}

      {ref, result} when ref == message_task.ref ->
        Process.demonitor(message_task.ref, [:flush])
        Process.sleep(@post_message_listener_drain_ms)
        stop_async_task(listener_task)
        result

      {ref, _result} when ref == listener_task.ref ->
        Process.demonitor(listener_task.ref, [:flush])

        await_turn_result(
          session,
          turn_ref,
          message_task,
          listener_task,
          started_at_ms,
          last_activity_ms,
          turn_timeout_ms,
          stall_timeout_ms
        )

      {:DOWN, ref, :process, _pid, reason} when ref == message_task.ref ->
        stop_async_task(listener_task)
        {:error, {:message_task_exit, reason}}

      {:DOWN, ref, :process, _pid, _reason} when ref == listener_task.ref ->
        await_turn_result(
          session,
          turn_ref,
          message_task,
          listener_task,
          started_at_ms,
          last_activity_ms,
          turn_timeout_ms,
          stall_timeout_ms
        )

      {port, {:data, {:eol, chunk}}} when port == session.port ->
        log_port_output("server", IO.chardata_to_string(chunk))

        await_turn_result(
          session,
          turn_ref,
          message_task,
          listener_task,
          started_at_ms,
          last_activity_ms,
          turn_timeout_ms,
          stall_timeout_ms
        )

      {port, {:data, {:noeol, chunk}}} when port == session.port ->
        log_port_output("server", IO.chardata_to_string(chunk))

        await_turn_result(
          session,
          turn_ref,
          message_task,
          listener_task,
          started_at_ms,
          last_activity_ms,
          turn_timeout_ms,
          stall_timeout_ms
        )

      {port, {:exit_status, status}} when port == session.port ->
        {:error, {:port_exit, status}}
    after
      @poll_interval_ms ->
        now_ms = System.monotonic_time(:millisecond)

        cond do
          turn_timeout_ms > 0 and now_ms - started_at_ms > turn_timeout_ms ->
            abort_session(session)
            {:error, :turn_timeout}

          stall_timeout_ms > 0 and now_ms - last_activity_ms > stall_timeout_ms ->
            abort_session(session)
            {:error, :stall_timeout}

          true ->
            await_turn_result(
              session,
              turn_ref,
              message_task,
              listener_task,
              started_at_ms,
              last_activity_ms,
              turn_timeout_ms,
              stall_timeout_ms
            )
        end
    end
  end

  defp stop_async_task(%Task{} = task) do
    Task.shutdown(task, :brutal_kill)
    :ok
  rescue
    _error ->
      :ok
  end

  defp stop_async_task(_task), do: :ok

  defp abort_session(session) do
    case Req.post(session.request, url: "/session/#{session.session_id}/abort", json: %{}) do
      {:ok, _response} -> :ok
      {:error, reason} -> Logger.debug("OpenCode abort failed: #{inspect(reason)}")
    end

    :ok
  end

  defp stream_session_events(session, turn_ref, owner, on_message) do
    response =
      Req.get!(session.request,
        url: "/global/event",
        decode_body: false,
        into: :self,
        headers: %{"accept" => "text/event-stream"}
      )

    receive_stream_events(response, "", session, turn_ref, owner, on_message)
  end

  defp receive_stream_events(response, buffer, session, turn_ref, owner, on_message) do
    receive do
      message ->
        case Req.parse_message(response, message) do
          {:ok, chunks} ->
            {next_buffer, continue?} =
              Enum.reduce_while(chunks, {buffer, true}, fn chunk, {buffer_acc, _continue?} ->
                case handle_stream_chunk(chunk, buffer_acc, session, turn_ref, owner, on_message) do
                  {:cont, next_buffer} -> {:cont, {next_buffer, true}}
                  {:halt, next_buffer} -> {:halt, {next_buffer, false}}
                end
              end)

            if continue? do
              receive_stream_events(response, next_buffer, session, turn_ref, owner, on_message)
            else
              :ok
            end

          :unknown ->
            receive_stream_events(response, buffer, session, turn_ref, owner, on_message)

          {:error, reason} ->
            send(owner, {turn_ref, :stream_error, {:event_stream_parse_failed, reason}})
            :ok
        end
    after
      @stream_idle_poll_ms ->
        receive_stream_events(response, buffer, session, turn_ref, owner, on_message)
    end
  end

  defp handle_stream_chunk({:data, data}, buffer, session, turn_ref, owner, on_message) do
    {next_buffer, events} = parse_sse_events(buffer, data)

    Enum.each(events, fn event ->
      handle_global_event(event, session, turn_ref, owner, on_message)
    end)

    {:cont, next_buffer}
  end

  defp handle_stream_chunk(:done, buffer, _session, _turn_ref, _owner, _on_message) do
    {:halt, buffer}
  end

  defp handle_stream_chunk(_chunk, buffer, _session, _turn_ref, _owner, _on_message) do
    {:cont, buffer}
  end

  defp parse_sse_events(buffer, data) do
    normalized = (buffer <> IO.iodata_to_binary(data)) |> String.replace("\r\n", "\n")
    parts = String.split(normalized, "\n\n")

    {complete_parts, rest} =
      if String.ends_with?(normalized, "\n\n") do
        {parts, ""}
      else
        {Enum.drop(parts, -1), List.last(parts) || ""}
      end

    events =
      complete_parts
      |> Enum.map(&parse_sse_block/1)
      |> Enum.reject(&is_nil/1)

    {rest, events}
  end

  defp parse_sse_block(block) when is_binary(block) do
    lines = String.split(block, "\n", trim: true)

    {event_name, data_lines} =
      Enum.reduce(lines, {nil, []}, fn line, {event_name_acc, data_acc} ->
        cond do
          String.starts_with?(line, "event:") ->
            {String.trim(String.replace_prefix(line, "event:", "")), data_acc}

          String.starts_with?(line, "data:") ->
            {event_name_acc, data_acc ++ [String.trim_leading(String.replace_prefix(line, "data:", ""))]}

          true ->
            {event_name_acc, data_acc}
        end
      end)

    payload =
      data_lines
      |> Enum.join("\n")
      |> case do
        "" ->
          nil

        json ->
          case Jason.decode(json) do
            {:ok, decoded} -> decoded
            {:error, _reason} -> nil
          end
      end

    case payload do
      %{} = decoded ->
        %{
          "event" => event_name,
          "payload" => decoded
        }

      _ ->
        nil
    end
  end

  defp handle_global_event(
         %{"payload" => %{"payload" => %{"type" => type, "properties" => properties}} = envelope},
         session,
         turn_ref,
         owner,
         on_message
       ) do
    if event_matches_session?(type, properties, session.session_id) do
      now_ms = System.monotonic_time(:millisecond)
      send(owner, {turn_ref, :activity, now_ms})

      usage = event_usage(type, properties)

      emit_message(
        on_message,
        type,
        %{
          payload: envelope,
          usage: usage
        },
        session.metadata
      )

      maybe_handle_runtime_event(type, properties, session, turn_ref, owner)
    end
  end

  defp handle_global_event(_event, _session, _turn_ref, _owner, _on_message), do: :ok

  defp maybe_handle_runtime_event("permission.asked", properties, session, _turn_ref, _owner) do
    decision = permission_reply(properties, session.workspace)
    reply_permission_request(session.request, session.session_id, properties, decision)
  end

  defp maybe_handle_runtime_event("question.asked", properties, session, turn_ref, owner) do
    reject_question_request(session.request, properties)
    send(owner, {turn_ref, :turn_failed, {:turn_input_required, properties}})
  end

  defp maybe_handle_runtime_event("session.error", properties, _session, turn_ref, owner) do
    send(owner, {turn_ref, :turn_failed, {:session_error, properties}})
  end

  defp maybe_handle_runtime_event("message.updated", %{"info" => %{"error" => error}}, _session, turn_ref, owner)
       when not is_nil(error) do
    send(owner, {turn_ref, :turn_failed, {:message_error, error}})
  end

  defp maybe_handle_runtime_event(_type, _properties, _session, _turn_ref, _owner), do: :ok

  defp event_matches_session?(_type, properties, expected_session_id) do
    case event_session_id(properties) do
      session_id when is_binary(session_id) -> session_id == expected_session_id
      _ -> false
    end
  end

  defp event_session_id(%{"sessionID" => session_id}) when is_binary(session_id), do: session_id
  defp event_session_id(%{sessionID: session_id}) when is_binary(session_id), do: session_id

  defp event_session_id(%{"info" => %{"sessionID" => session_id}}) when is_binary(session_id),
    do: session_id

  defp event_session_id(%{info: %{sessionID: session_id}}) when is_binary(session_id), do: session_id

  defp event_session_id(%{"part" => %{"sessionID" => session_id}}) when is_binary(session_id),
    do: session_id

  defp event_session_id(%{part: %{sessionID: session_id}}) when is_binary(session_id), do: session_id
  defp event_session_id(_properties), do: nil

  defp reply_permission_request(request, session_id, properties, decision) do
    permission_id = Map.get(properties, "id") || Map.get(properties, :id)

    if is_binary(permission_id) do
      case Req.post(request,
             url: "/session/#{session_id}/permissions/#{permission_id}",
             json: %{"response" => decision}
           ) do
        {:ok, _response} ->
          :ok

        {:error, reason} ->
          Logger.debug("OpenCode permission reply failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp reject_question_request(request, properties) do
    request_id = Map.get(properties, "id") || Map.get(properties, :id)

    if is_binary(request_id) do
      case Req.post(request, url: "/question/#{request_id}/reject", json: %{}) do
        {:ok, _response} ->
          :ok

        {:error, reason} ->
          Logger.debug("OpenCode question reject failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp permission_reply(properties, workspace) do
    permission = Map.get(properties, "permission") || Map.get(properties, :permission)

    cond do
      permission == "external_directory" ->
        "reject"

      permission not in @allowed_unattended_permissions ->
        "reject"

      permission_patterns_within_workspace?(properties, workspace) ->
        "once"

      true ->
        "reject"
    end
  end

  defp permission_patterns_within_workspace?(properties, workspace) do
    patterns =
      Map.get(properties, "patterns") ||
        Map.get(properties, :patterns) ||
        []

    patterns != [] and Enum.all?(patterns, &pattern_within_workspace?(&1, workspace))
  end

  defp pattern_within_workspace?(pattern, workspace)
       when is_binary(pattern) and is_binary(workspace) do
    trimmed = String.trim(pattern)

    cond do
      trimmed == "" ->
        false

      String.contains?(trimmed, ["\n", "\r", <<0>>]) ->
        false

      Path.type(trimmed) == :absolute ->
        absolute_scope_within_workspace?(trimmed, workspace)

      true ->
        relative_scope_within_workspace?(trimmed, workspace)
    end
  end

  defp pattern_within_workspace?(_pattern, _workspace), do: false

  defp absolute_scope_within_workspace?(pattern, workspace) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         prefix <- wildcard_free_prefix(pattern),
         {:ok, canonical_prefix} <- PathSafety.canonicalize(prefix) do
      canonical_prefix == canonical_workspace or
        String.starts_with?(canonical_prefix <> "/", canonical_workspace <> "/")
    else
      _ -> false
    end
  end

  defp relative_scope_within_workspace?(pattern, workspace) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         prefix <- wildcard_free_prefix(pattern),
         expanded_prefix <- Path.expand(prefix, workspace),
         {:ok, canonical_prefix} <- PathSafety.canonicalize(expanded_prefix) do
      canonical_prefix == canonical_workspace or
        String.starts_with?(canonical_prefix <> "/", canonical_workspace <> "/")
    else
      _ -> false
    end
  end

  defp wildcard_free_prefix(pattern) do
    pattern
    |> String.split(~r/[*?{\[]/, parts: 2)
    |> List.first()
    |> then(fn prefix -> if prefix in [nil, ""], do: ".", else: prefix end)
  end

  defp event_usage("message.updated", %{"info" => info}), do: message_info_token_usage(info)
  defp event_usage("message.updated", %{info: info}), do: message_info_token_usage(info)

  defp event_usage("message.part.updated", %{"part" => part}), do: part_token_usage(part)
  defp event_usage("message.part.updated", %{part: part}), do: part_token_usage(part)
  defp event_usage(_type, _properties), do: nil

  defp message_response_token_usage(%{"info" => info}) when is_map(info), do: message_info_token_usage(info)
  defp message_response_token_usage(_response), do: nil

  defp message_info_token_usage(%{"tokens" => tokens}), do: normalize_token_usage(tokens)
  defp message_info_token_usage(%{tokens: tokens}), do: normalize_token_usage(tokens)
  defp message_info_token_usage(_info), do: nil

  defp part_token_usage(%{"type" => "step-finish", "tokens" => tokens}), do: normalize_token_usage(tokens)
  defp part_token_usage(%{type: "step-finish", tokens: tokens}), do: normalize_token_usage(tokens)
  defp part_token_usage(_part), do: nil

  defp normalize_token_usage(tokens) when is_map(tokens) do
    input = token_value(tokens, ["input", :input])
    output = token_value(tokens, ["output", :output])
    reasoning = token_value(tokens, ["reasoning", :reasoning])

    %{
      input: input,
      output: output,
      reasoning: reasoning,
      total: input + output + reasoning
    }
  end

  defp normalize_token_usage(_tokens), do: nil

  defp token_value(tokens, keys) do
    case Enum.find_value(keys, &Map.get(tokens, &1)) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp issue_title(%{identifier: identifier, title: title})
       when is_binary(identifier) and is_binary(title) do
    "#{identifier}: #{title}"
  end

  defp issue_title(%{title: title}) when is_binary(title), do: title
  defp issue_title(_issue), do: "agent turn"

  defp sleep_or_timeout(deadline_ms, timeout_reason, next_fun) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      {:error, timeout_reason}
    else
      Process.sleep(@poll_interval_ms)
      next_fun.()
    end
  end

  defp stop_port(port) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    _error ->
      :ok
  end

  defp log_port_output(stream_label, line) when is_binary(line) do
    text =
      line
      |> String.trim_trailing()
      |> truncate_output()

    if text != "" do
      Logger.debug("OpenCode #{stream_label} output: #{text}")
    end
  end

  defp truncate_output(text) when byte_size(text) > @port_log_preview_bytes do
    binary_part(text, 0, @port_log_preview_bytes) <> "..."
  end

  defp truncate_output(text), do: text

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
      Logger.debug("OpenCode on_message callback failed: #{Exception.message(error)}")
      :ok
  end

  defp default_on_message(_message), do: :ok
end
