defmodule SymphonyElixirWeb.RunnerController do
  @moduledoc """
  The controller side of the runner protocol: `/runner/v1/runs/:run_id/...`.

  `SymphonyElixirWeb.RunnerAuth` has already checked the run token and epoch.
  These actions turn a runner's events into the same orchestrator messages and
  `Transcript` calls `SymphonyElixir.RunHost.Local` makes in-process, and
  expose the session store, the dashboard inbox and the steering command
  queue. Event seqs are deduplicated by `SymphonyElixir.RunnerCommands`, so a
  runner replaying its outbox applies each event once.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.AgentInbox
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunEvents
  alias SymphonyElixir.RunnerCommands
  alias SymphonyElixir.SessionStore
  alias SymphonyElixir.Transcript
  alias SymphonyElixirWeb.Endpoint

  @max_wait_ms 25_000
  @default_wait_ms 20_000

  @doc "Applies a batch of runner events, once each, in seq order."
  @spec events(Conn.t(), map()) :: Conn.t()
  def events(%Conn{assigns: %{run_id: run_id}} = conn, params) do
    case decode_events(params) do
      {:ok, events} -> apply_events(conn, run_id, events)
      {:error, :invalid_events} -> error(conn, 400, "invalid_events")
    end
  end

  @spec session(Conn.t(), map()) :: Conn.t()
  def session(%Conn{assigns: %{issue_id: issue_id}} = conn, _params) do
    json(conn, %{record: SessionStore.get(issue_id)})
  end

  @spec put_session(Conn.t(), map()) :: Conn.t()
  def put_session(%Conn{assigns: %{issue_id: issue_id}} = conn, params) do
    case params do
      %{"record" => %{} = record} ->
        :ok = SessionStore.put(issue_id, record)
        json(conn, %{ok: true})

      _ ->
        error(conn, 400, "invalid_record")
    end
  end

  @spec delete_session(Conn.t(), map()) :: Conn.t()
  def delete_session(%Conn{assigns: %{issue_id: issue_id}} = conn, _params) do
    :ok = SessionStore.delete(issue_id)
    json(conn, %{ok: true})
  end

  @spec inbox_take(Conn.t(), map()) :: Conn.t()
  def inbox_take(%Conn{assigns: %{identifier: identifier}} = conn, _params) do
    messages = identifier |> AgentInbox.take_queued() |> RunEvents.encode()
    json(conn, %{messages: messages})
  end

  @spec inbox_queued(Conn.t(), map()) :: Conn.t()
  def inbox_queued(%Conn{assigns: %{identifier: identifier}} = conn, _params) do
    json(conn, %{queued: AgentInbox.queued?(identifier)})
  end

  @spec inbox_get(Conn.t(), map()) :: Conn.t()
  def inbox_get(%Conn{assigns: %{identifier: identifier}} = conn, %{"message_id" => message_id}) do
    message = AgentInbox.get(identifier, message_id)
    json(conn, %{message: if(message, do: RunEvents.encode(message), else: nil)})
  end

  @spec inbox_delivered(Conn.t(), map()) :: Conn.t()
  def inbox_delivered(%Conn{assigns: %{identifier: identifier}} = conn, %{
        "message_id" => message_id,
        "delivery" => delivery
      })
      when delivery in ["steered", "next_turn"] do
    :ok = AgentInbox.mark_delivered(identifier, message_id, delivery)
    json(conn, %{ok: true})
  end

  def inbox_delivered(conn, _params), do: error(conn, 400, "invalid_delivery")

  @spec codex_turn(Conn.t(), map()) :: Conn.t()
  def codex_turn(%Conn{assigns: %{identifier: identifier, issue_id: issue_id}} = conn, params) do
    case normalize_steer(params["steer"]) do
      {:ok, steer} ->
        issue = %Issue{id: issue_id, identifier: identifier}
        :ok = AgentInbox.register_remote_runner(identifier, issue_id)
        :ok = AgentInbox.codex_turn(issue, steer)
        json(conn, %{ok: true})

      :error ->
        error(conn, 400, "invalid_steer")
    end
  end

  @doc "Long-polls for commands for the run's issue (steering dashboard messages)."
  @spec commands(Conn.t(), map()) :: Conn.t()
  def commands(%Conn{assigns: %{identifier: identifier}} = conn, params) do
    after_seq = integer_param(params, "after", 0)
    wait_ms = params |> integer_param("wait_ms", @default_wait_ms) |> min(@max_wait_ms) |> max(0)

    commands =
      identifier
      |> RunnerCommands.fetch(after_seq, wait_ms)
      |> Enum.map(fn command ->
        %{"seq" => command.seq, "type" => command.type, "message_id" => command.message_id}
      end)

    json(conn, %{commands: commands})
  end

  defp apply_events(conn, run_id, events) do
    case RunnerCommands.apply_events(run_id, events, &apply_event(conn, &1)) do
      {:ok, last_seq} -> json(conn, %{applied_through: last_seq})
      {:error, :finished} -> error(conn, 409, "finished")
      {:error, :unavailable} -> error(conn, 503, "unavailable")
    end
  end

  defp decode_events(%{"events" => events}) when is_list(events) do
    events
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, acc} ->
      case decode_event(event) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        :error -> {:halt, {:error, :invalid_events}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp decode_events(_params), do: {:error, :invalid_events}

  defp decode_event(%{"seq" => seq, "type" => type, "data" => data})
       when is_integer(seq) and seq >= 0 and is_binary(type) do
    case RunEvents.decode(data) do
      {:ok, term} -> {:ok, %{seq: seq, type: type, data: term}}
      {:error, :invalid} -> :error
    end
  end

  defp decode_event(_event), do: :error

  defp apply_event(conn, %{type: "runtime_info", data: data}) do
    send(
      orchestrator(),
      {:worker_runtime_info, issue_id(conn, data),
       %{
         worker_host: data_value(data, :worker_host),
         workspace_path: data_value(data, :workspace_path)
       }}
    )
  end

  defp apply_event(conn, %{type: "agent_update", data: data}) do
    backend = data_value(data, :backend) || conn.assigns.backend
    message = data_value(data, :message)
    Transcript.record(identifier(conn, data), message, backend: backend)
    send_agent_update(conn.assigns.issue_id, backend, message)
  end

  defp apply_event(conn, %{type: "transcript_note", data: data}) do
    Transcript.note(identifier(conn, data), data_value(data, :text))
  end

  defp apply_event(conn, %{type: "turn_started", data: data}) do
    Transcript.turn_started(identifier(conn, data), data_value(data, :info))
  end

  defp apply_event(_conn, %{type: "heartbeat"}), do: :ok

  defp apply_event(conn, %{type: "finished", data: data}) do
    reason = data_value(data, :reason)
    send(orchestrator(), {:run_finished, conn.assigns.issue_id, conn.assigns.run_id, reason})
    Logger.info("Runner finished issue_id=#{conn.assigns.issue_id} run_id=#{conn.assigns.run_id} reason=#{inspect(reason)}")
  end

  defp apply_event(conn, %{type: type}) do
    Logger.warning("Runner sent an unknown event type=#{inspect(type)} run_id=#{conn.assigns.run_id}")
  end

  defp identifier(conn, data), do: data_value(data, :identifier) || conn.assigns.identifier
  defp issue_id(conn, data), do: data_value(data, :issue_id) || conn.assigns.issue_id

  defp send_agent_update(issue_id, "codex", message), do: send(orchestrator(), {:codex_worker_update, issue_id, message})
  defp send_agent_update(issue_id, _backend, message), do: send(orchestrator(), {:agent_worker_update, issue_id, message})

  defp data_value(data, key) when is_map(data), do: Map.get(data, key) || Map.get(data, Atom.to_string(key))
  defp data_value(_data, _key), do: nil

  defp normalize_steer(nil), do: {:ok, nil}

  defp normalize_steer(%{} = steer) do
    thread_id = steer["thread_id"] || steer[:thread_id]
    turn_id = steer["turn_id"] || steer[:turn_id]

    if is_binary(thread_id) and is_binary(turn_id) do
      {:ok, %{thread_id: thread_id, turn_id: turn_id}}
    else
      :error
    end
  end

  defp normalize_steer(_steer), do: :error

  defp integer_param(params, key, default) do
    case params[key] do
      value when is_integer(value) and value >= 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer >= 0 -> integer
          _ -> default
        end

      _ ->
        default
    end
  end

  defp orchestrator do
    Application.get_env(:symphony_elixir, Endpoint, [])[:orchestrator] || SymphonyElixir.Orchestrator
  end

  defp error(conn, status, error) do
    conn
    |> put_status(status)
    |> json(%{error: error})
  end
end
