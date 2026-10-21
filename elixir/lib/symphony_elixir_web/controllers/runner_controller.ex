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
  alias SymphonyElixir.AgentMetrics
  alias SymphonyElixir.Capacity.RunUsage
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHubApp.RunCredentials
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunEvents
  alias SymphonyElixir.RunnerCommands
  alias SymphonyElixir.RunRegistry
  alias SymphonyElixir.RunSpec
  alias SymphonyElixir.RunWatcher
  alias SymphonyElixir.SessionStore
  alias SymphonyElixir.Transcript
  alias SymphonyElixirWeb.Endpoint
  alias SymphonyElixirWeb.RateLimit

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

  @doc """
  A fresh GitHub App installation token for the run's home repository only,
  with `github_app.permissions`: `{"token", "expires_at", "host"}`. The run's
  issue is the one in the run registry, so a run token can never get a token
  for another run's repository. `404 github_app_not_configured` without
  `github_app`, `429` past the per-run limit, `502 token_unavailable` when
  GitHub refuses. Cached tokens with at least 50 minutes left are reused.
  """
  @spec github_token(Conn.t(), map()) :: Conn.t()
  def github_token(%Conn{assigns: %{run_id: run_id, run: run}} = conn, _params) do
    with :ok <- RateLimit.check(:runner_github_token, run_id),
         {:ok, settings} <- Config.settings(),
         {:ok, body} <- RunCredentials.refresh(run_spec(run_id, run), settings) do
      json(conn, body)
    else
      {:error, retry_after} when is_integer(retry_after) ->
        conn
        |> Conn.put_resp_header("retry-after", Integer.to_string(retry_after))
        |> error(429, "rate_limited")

      {:error, :github_app_not_configured} ->
        error(conn, 404, "github_app_not_configured")

      {:error, reason} ->
        Logger.warning("GitHub App token refresh failed run_id=#{run_id} reason=#{inspect(reason, limit: 5)}")
        error(conn, 502, "token_unavailable")
    end
  end

  # The registry's issue (labels included) picks the home repo exactly as the
  # launch did.
  defp run_spec(run_id, run) do
    metadata = Map.get(run, :metadata) || %{}

    issue =
      metadata[:issue] ||
        %{
          id: nil,
          identifier: metadata[:identifier],
          project_slug: metadata[:project_slug],
          labels: metadata[:labels] || []
        }

    %RunSpec{run_id: run_id, epoch: run.epoch, issue: issue}
  end

  defp apply_events(conn, run_id, events) do
    case RunnerCommands.apply_events(run_id, events, &apply_event(conn, &1)) do
      {:ok, last_seq} ->
        # One write per applied batch, not per event. This keeps the seq across
        # a controller restart with a bounded cost; a crash can still replay
        # the last batch, whose transcript entries are then duplicated.
        RunRegistry.advance_progress(
          conn.assigns.issue_id,
          run_id,
          last_seq,
          RunnerCommands.finished_reason(run_id)
        )

        json(conn, %{applied_through: last_seq})

      {:error, :finished} ->
        error(conn, 409, "finished")

      {:error, :unavailable} ->
        error(conn, 503, "unavailable")
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

  defp apply_event(conn, event) do
    RunWatcher.touch(conn.assigns.run_id)
    RunUsage.mark_remote(conn.assigns.issue_id)
    do_apply_event(conn, event)
  end

  defp do_apply_event(conn, %{type: "runtime_info", data: data}) do
    send(
      orchestrator(),
      {:worker_runtime_info, issue_id(conn, data),
       %{
         worker_host: data_value(data, :worker_host),
         workspace_path: data_value(data, :workspace_path)
       }}
    )
  end

  defp do_apply_event(conn, %{type: "route_info", data: data}) do
    send(
      orchestrator(),
      {:worker_runtime_info, issue_id(conn, data),
       %{
         backend: data_value(data, :backend),
         effort: data_value(data, :effort)
       }}
    )
  end

  defp do_apply_event(conn, %{type: "agent_update", data: data}) do
    backend = data_value(data, :backend) || conn.assigns.backend
    message = data_value(data, :message)
    Transcript.record(identifier(conn, data), message, backend: backend)
    AgentMetrics.tool_call(message, backend)
    send_agent_update(conn.assigns.issue_id, backend, message)
  end

  defp do_apply_event(conn, %{type: "transcript_note", data: data}) do
    Transcript.note(identifier(conn, data), data_value(data, :text))
  end

  defp do_apply_event(conn, %{type: "turn_started", data: data}) do
    info = data_value(data, :info)
    AgentMetrics.turn_started(info)
    Transcript.turn_started(identifier(conn, data), info)
  end

  defp do_apply_event(_conn, %{type: "heartbeat"}), do: :ok

  # The runner's own CPU and memory (SymphonyElixir.Capacity.UsageReporter).
  defp do_apply_event(conn, %{type: "metrics", data: data}), do: RunUsage.report(conn.assigns.issue_id, data)

  defp do_apply_event(conn, %{type: "finished", data: data}) do
    reason = data_value(data, :reason)
    send(orchestrator(), {:run_finished, conn.assigns.issue_id, conn.assigns.run_id, reason})
    Logger.info("Runner finished issue_id=#{conn.assigns.issue_id} run_id=#{conn.assigns.run_id} reason=#{inspect(reason)}")
  end

  defp do_apply_event(conn, %{type: type}) do
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
