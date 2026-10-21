defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Accounts, Codex.DynamicTool, Codex.TraceLog, Config, RunHost, Sandbox, SSH, Telemetry}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @thread_resume_id 4
  @steer_id_prefix "symphony-steer:"
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."

  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          resumed: boolean(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          account: map() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, Keyword.put(opts, :issue, issue)) do
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
    account = Keyword.get(opts, :account)
    command = Keyword.get(opts, :command) || Config.codex_command(Keyword.get(opts, :effort))
    issue = Keyword.get(opts, :issue)
    command = codex_launch_command(command, issue)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host, command, issue, account) do
      metadata = port_metadata(port, worker_host, account)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread_id, resumed?} <-
             do_start_session(port, expanded_workspace, session_policies, Keyword.get(opts, :resume_thread_id)) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           resumed: resumed?,
           workspace: expanded_workspace,
           worker_host: worker_host,
           account: account
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_number = Keyword.get(opts, :turn_number, 1)
    host = Keyword.get(opts, :run_host) || RunHost.local()

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments)
      end)

    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")
        TraceLog.put_context(trace_context(issue, session_id, thread_id, turn_id, turn_number))

        loop_ctx = %{
          tool_executor: tool_executor,
          auto_approve_requests: auto_approve_requests,
          host: host,
          issue: issue,
          thread_id: thread_id,
          turn_id: turn_id,
          steering: MapSet.new()
        }

        # Dashboard messages for this issue now reach this process to steer the turn.
        RunHost.codex_turn(host, issue, %{thread_id: thread_id, turn_id: turn_id})

        try do
          emit_message(
            on_message,
            :session_started,
            %{
              session_id: session_id,
              thread_id: thread_id,
              turn_id: turn_id
            },
            metadata
          )

          case await_turn_completion(port, on_message, loop_ctx) do
            {:ok, result} ->
              Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

              {:ok,
               %{
                 result: result,
                 session_id: session_id,
                 thread_id: thread_id,
                 turn_id: turn_id
               }}

            {:error, reason} ->
              Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

              emit_message(
                on_message,
                :turn_ended_with_error,
                %{
                  session_id: session_id,
                  reason: reason
                },
                metadata
              )

              {:error, reason}
          end
        after
          RunHost.codex_turn(host, issue, nil)
          TraceLog.clear_context()
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    case Config.validate_workspace_path(workspace) do
      {:ok, canonical_workspace} ->
        {:ok, canonical_workspace}

      {:error, {:workspace_root, canonical_workspace, _canonical_root}} ->
        {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

      {:error, {:symlink_escape, expanded_workspace, canonical_root}} ->
        {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

      {:error, {:outside_workspace_root, canonical_workspace, canonical_root}} ->
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}

      {:error, {:path_unreadable, path, reason}} ->
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

  defp codex_launch_command(command, issue) do
    Enum.reduce(Telemetry.codex_config_overrides(issue), command, &Config.with_codex_config(&2, shell_escape(&1)))
  end

  defp start_port(workspace, nil, command, issue, account) do
    environment = port_environment(issue, account)
    env_names = Enum.map(environment, fn {key, _value} -> to_string(key) end)

    with {:ok, spec} <- Sandbox.command_spec(workspace, command, env_names) do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(spec.executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(spec.args, &String.to_charlist/1),
            env: environment,
            line: @port_line_bytes
          ]
          |> maybe_put_cd(spec.cd)
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, command, issue, account) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, command, issue, account)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp maybe_put_cd(port_opts, nil), do: port_opts
  defp maybe_put_cd(port_opts, cd), do: Keyword.put(port_opts, :cd, String.to_charlist(cd))

  defp remote_launch_command(workspace, command, issue, account) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      remote_environment_exports(issue, account),
      "exec #{command}"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" && ")
  end

  defp remote_environment_exports(issue, account) do
    env_pairs(issue, account)
    |> Enum.map_join(" && ", fn {key, value} -> "export #{key}=#{shell_escape(to_string(value))}" end)
  end

  defp port_environment(issue, account) do
    env_pairs(issue, account)
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(to_string(value))}
    end)
  end

  defp env_pairs(issue, account) do
    settings = Config.settings!()
    tracker = settings.tracker

    []
    |> maybe_put_env("SYMPHONY_LINEAR_API_KEY", tracker.kind == "linear" && tracker.api_key)
    |> maybe_put_env("SYMPHONY_LINEAR_ENDPOINT", tracker.kind == "linear" && tracker.endpoint)
    |> maybe_put_env("OPENROUTER_API_KEY", settings.providers.openrouter_api_key)
    |> Kernel.++(Accounts.credential_env(account))
    |> Kernel.++(Telemetry.env_pairs("codex", issue, account))
  end

  defp maybe_put_env(entries, _key, nil), do: entries
  defp maybe_put_env(entries, _key, false), do: entries
  defp maybe_put_env(entries, key, value), do: [{key, value} | entries]

  defp port_metadata(port, worker_host, account \\ nil) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    base_metadata =
      case worker_host do
        host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
        _ -> base_metadata
      end

    case Accounts.account_summary(account) do
      nil -> base_metadata
      account_summary -> Map.put(base_metadata, :account, account_summary)
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  # With a thread id from an interrupted run, rejoin that thread (Codex keeps it
  # on disk in the sandbox's ~/.codex); if it's gone, start a new one.
  defp do_start_session(port, workspace, session_policies, resume_thread_id) do
    with :ok <- send_initialize(port), do: open_thread(port, workspace, session_policies, resume_thread_id)
  end

  defp open_thread(port, workspace, session_policies, resume_thread_id) when is_binary(resume_thread_id) do
    case resume_thread(port, workspace, session_policies, resume_thread_id) do
      {:ok, thread_id} ->
        {:ok, thread_id, true}

      failure ->
        Logger.warning("Could not resume Codex thread #{resume_thread_id}; starting a new one: #{inspect(failure)}")
        open_thread(port, workspace, session_policies, nil)
    end
  end

  defp open_thread(port, workspace, session_policies, _resume_thread_id) do
    with {:ok, thread_id} <- start_thread(port, workspace, session_policies), do: {:ok, thread_id, false}
  end

  defp resume_thread(port, workspace, %{approval_policy: approval_policy, thread_sandbox: thread_sandbox}, thread_id) do
    send_message(port, %{
      "method" => "thread/resume",
      "id" => @thread_resume_id,
      "params" =>
        %{"threadId" => thread_id, "approvalPolicy" => approval_policy, "sandbox" => thread_sandbox, "cwd" => workspace}
        |> put_model(Config.settings!().codex.model)
    })

    case await_response(port, @thread_resume_id) do
      {:ok, %{"thread" => %{"id" => ^thread_id}}} -> {:ok, thread_id}
      {:ok, other} -> {:error, {:unexpected_resume_payload, other}}
      other -> other
    end
  end

  defp start_thread(port, workspace, %{approval_policy: approval_policy, thread_sandbox: thread_sandbox}) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" =>
        %{
          "approvalPolicy" => approval_policy,
          "sandbox" => thread_sandbox,
          "cwd" => workspace,
          "dynamicTools" => DynamicTool.tool_specs()
        }
        |> put_model(Config.settings!().codex.model)
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  # `codex.model` names the model explicitly: Codex otherwise uses the model
  # from the host's ~/.codex/config.toml, whatever the command line says.
  defp put_model(params, model) when is_binary(model) and model != "", do: Map.put(params, "model", model)
  defp put_model(params, _model), do: params

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, ctx) do
    receive_loop(port, on_message, Config.settings!().codex.turn_timeout_ms, "", ctx)
  end

  # `ctx` carries the tool executor, approval mode, and the active turn (for
  # `turn/steer`). Dashboard messages arrive as `{:agent_inbox, message_id}`.
  defp receive_loop(port, on_message, timeout_ms, pending_line, ctx) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, ctx)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, timeout_ms, pending_line <> to_string(chunk), ctx)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}

      {:agent_inbox, message_id} when is_binary(message_id) ->
        receive_loop(port, on_message, timeout_ms, pending_line, steer(port, ctx, message_id))
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp steer(port, %{issue: %{identifier: identifier}, turn_id: turn_id} = ctx, message_id)
       when is_binary(identifier) and is_binary(turn_id) do
    with false <- MapSet.member?(ctx.steering, message_id),
         %{status: "queued"} = message <- RunHost.inbox_get(ctx.host, identifier, message_id) do
      send_message(port, %{
        "id" => @steer_id_prefix <> message_id,
        "method" => "turn/steer",
        "params" => %{
          "threadId" => ctx.thread_id,
          "expectedTurnId" => turn_id,
          "input" => [%{"type" => "text", "text" => RunHost.inbox_steer_text(ctx.host, message)}]
        }
      })

      %{ctx | steering: MapSet.put(ctx.steering, message_id)}
    else
      _ -> ctx
    end
  end

  defp steer(_port, ctx, _message_id), do: ctx

  # The steer response arrives among the turn's notifications. On an error
  # (the turn ended, or another turn is active) the message stays queued for
  # the next turn prompt.
  defp handle_steer_response(message_id, payload, ctx) do
    case payload do
      %{"result" => %{}} ->
        Logger.info("Steered Codex turn with a dashboard message #{issue_context(ctx.issue)} message_id=#{message_id}")
        RunHost.inbox_mark_delivered(ctx.host, ctx.issue.identifier, message_id, "steered")

      other ->
        reason = inspect(other["error"] || other, limit: 5)
        Logger.info("Codex turn/steer failed #{issue_context(ctx.issue)} message_id=#{message_id}: #{reason}")
    end

    %{ctx | steering: MapSet.delete(ctx.steering, message_id)}
  end

  defp track_turn(ctx, %{"method" => "turn/started", "params" => %{"turn" => %{"id" => turn_id}}})
       when is_binary(turn_id) do
    if turn_id != ctx.turn_id, do: RunHost.codex_turn(ctx.host, ctx.issue, %{thread_id: ctx.thread_id, turn_id: turn_id})
    %{ctx | turn_id: turn_id}
  end

  defp track_turn(ctx, _payload), do: ctx

  defp handle_incoming(port, on_message, data, timeout_ms, ctx) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(port, on_message, payload, payload_string, method, timeout_ms, track_turn(ctx, payload))

      {:ok, %{"id" => @steer_id_prefix <> message_id} = payload} ->
        receive_loop(port, on_message, timeout_ms, "", handle_steer_response(message_id, payload, ctx))

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", ctx)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, timeout_ms, "", ctx)
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(port, on_message, payload, payload_string, method, timeout_ms, ctx) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           ctx.tool_executor,
           ctx.auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", ctx)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", ctx)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    reply_with_non_interactive_tool_input_answer(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata
    )
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp trace_context(issue, session_id, thread_id, turn_id, turn_number) do
    %{
      issue_id: Map.get(issue, :id) || Map.get(issue, "id"),
      issue_identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      session_id: session_id,
      thread_id: thread_id,
      turn_id: turn_id,
      turn_number: turn_number
    }
  end

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

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(TraceLog.context_metadata())
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())
      |> TraceLog.with_sequence()

    TraceLog.emit(message)
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
