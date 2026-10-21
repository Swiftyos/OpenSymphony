defmodule SymphonyElixir.RunHost.Remote do
  @moduledoc """
  A run host that talks to the controller over HTTP.

  Fire-and-forget calls (runtime info, agent updates, transcript notes, turn
  starts) are appended to a `SymphonyElixir.RunOutbox`, which posts them in
  batches and keeps them until the controller acknowledges them. Calls that
  need an answer (sessions, the inbox, Codex turns) are ordinary `Req`
  requests with a short retry; when the controller is unreachable reads
  degrade to nil or empty so the agent can keep working. Steering arrives
  through a command long-poll started by `inbox_register/3`. See
  `docs/durable-runs.md`.
  """

  @behaviour SymphonyElixir.RunHost

  alias SymphonyElixir.AgentInbox
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunEvents
  alias SymphonyElixir.RunnerCommandPoller
  alias SymphonyElixir.RunOutbox

  @request_timeout_ms 5_000
  @retries 3

  defstruct [:base_url, :run_id, :token, :outbox]

  @type t :: %__MODULE__{
          base_url: String.t(),
          run_id: String.t(),
          token: String.t(),
          outbox: pid() | nil
        }

  @impl true
  def runtime_info(%__MODULE__{outbox: outbox}, %Issue{id: issue_id}, worker_host, workspace) do
    append(outbox, "runtime_info", %{issue_id: issue_id, worker_host: worker_host, workspace_path: workspace})
  end

  @impl true
  def agent_update(%__MODULE__{outbox: outbox}, issue, backend, message) do
    append(outbox, "agent_update", %{
      issue_id: Map.get(issue, :id),
      identifier: Map.get(issue, :identifier),
      backend: backend,
      message: message
    })
  end

  @impl true
  def transcript_note(%__MODULE__{outbox: outbox}, identifier, text) do
    append(outbox, "transcript_note", %{identifier: identifier, text: text})
  end

  @impl true
  def turn_started(%__MODULE__{outbox: outbox}, identifier, info) do
    append(outbox, "turn_started", %{identifier: identifier, info: info})
  end

  @impl true
  def session_get(%__MODULE__{} = host, _issue_id) do
    case request(host, :get, "/session") do
      {:ok, %{"record" => record}} when is_map(record) -> record
      _ -> nil
    end
  end

  @impl true
  def session_put(%__MODULE__{} = host, _issue_id, record) do
    case request(host, :put, "/session", json: %{record: record}) do
      {:ok, _body} -> :ok
      _ -> :ok
    end
  end

  @impl true
  def session_delete(%__MODULE__{} = host, _issue_id) do
    case request(host, :delete, "/session") do
      {:ok, _body} -> :ok
      _ -> :ok
    end
  end

  @impl true
  def inbox_register(%__MODULE__{} = host, issue, _backend) do
    identifier = Map.get(issue, :identifier)

    if is_binary(identifier) and RunnerCommandPoller.available?() do
      RunnerCommandPoller.start(host, identifier, self())
    end

    :ok
  end

  @impl true
  def inbox_unregister(%__MODULE__{}, identifier) when is_binary(identifier) do
    RunnerCommandPoller.stop(identifier)
    :ok
  end

  def inbox_unregister(_host, _identifier), do: :ok

  @impl true
  def inbox_take_queued(%__MODULE__{} = host, _identifier) do
    with {:ok, %{"messages" => encoded}} <- request(host, :post, "/inbox/take", json: %{}),
         {:ok, messages} <- RunEvents.decode(encoded),
         true <- is_list(messages) do
      messages
    else
      _ -> []
    end
  end

  @impl true
  def inbox_queued?(%__MODULE__{} = host, _identifier) do
    case request(host, :get, "/inbox/queued") do
      {:ok, %{"queued" => queued}} -> queued == true
      _ -> false
    end
  end

  @impl true
  def inbox_prompt_section(_host, messages), do: AgentInbox.prompt_section(messages)

  @impl true
  def codex_turn(%__MODULE__{} = host, _issue, steer) do
    case request(host, :post, "/codex_turn", json: %{steer: encode_steer(steer)}) do
      {:ok, _body} -> :ok
      _ -> :ok
    end
  end

  @impl true
  def inbox_get(%__MODULE__{} = host, _identifier, id) when is_binary(id) do
    with {:ok, %{"message" => encoded}} when is_binary(encoded) <- request(host, :get, "/inbox/#{id}"),
         {:ok, message} <- RunEvents.decode(encoded) do
      message
    else
      _ -> nil
    end
  end

  def inbox_get(_host, _identifier, _id), do: nil

  @impl true
  def inbox_steer_text(_host, message), do: AgentInbox.steer_text(message)

  @impl true
  def inbox_mark_delivered(%__MODULE__{} = host, _identifier, id, delivery) when is_binary(id) do
    case request(host, :post, "/inbox/#{id}/delivered", json: %{delivery: delivery}) do
      {:ok, _body} -> :ok
      _ -> :ok
    end
  end

  def inbox_mark_delivered(_host, _identifier, _id, _delivery), do: :ok

  @doc """
  The commands queued for this run after `after_seq`, long-polling up to
  `wait_ms`. Used by `SymphonyElixir.RunnerCommandPoller`.
  """
  @spec commands(t(), non_neg_integer(), non_neg_integer()) :: [map()]
  def commands(%__MODULE__{} = host, after_seq, wait_ms) do
    params = [after: after_seq, wait_ms: wait_ms]

    case request(host, :get, "/commands", params: params, receive_timeout: wait_ms + 1_000) do
      {:ok, %{"commands" => commands}} when is_list(commands) -> commands
      _ -> []
    end
  end

  defp append(nil, _type, _data), do: :ok

  defp append(outbox, type, data) do
    RunOutbox.append(outbox, type, data)
    :ok
  end

  defp encode_steer(nil), do: nil

  defp encode_steer(steer) when is_map(steer) do
    %{
      "thread_id" => Map.get(steer, :thread_id) || Map.get(steer, "thread_id"),
      "turn_id" => Map.get(steer, :turn_id) || Map.get(steer, "turn_id")
    }
  end

  defp request(host, method, path, opts \\ []) do
    url = String.trim_trailing(host.base_url || "", "/") <> "/runner/v1/runs/#{host.run_id}" <> path

    request = [
      method: method,
      url: url,
      headers: [{"authorization", "Bearer #{host.token}"}],
      receive_timeout: Keyword.get(opts, :receive_timeout, @request_timeout_ms),
      retry: false
    ]

    request =
      opts
      |> Keyword.drop([:receive_timeout])
      |> Enum.reduce(request, fn {key, value}, acc -> Keyword.put(acc, key, value) end)

    attempt(request, @retries)
  end

  defp attempt(request, attempts_left) do
    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 409}} ->
        {:error, :stale_epoch}

      {:ok, %Req.Response{status: status}} ->
        if attempts_left > 1 do
          Process.sleep(100)
          attempt(request, attempts_left - 1)
        else
          {:error, {:status, status}}
        end

      {:error, reason} ->
        if attempts_left > 1 do
          Process.sleep(100)
          attempt(request, attempts_left - 1)
        else
          {:error, reason}
        end
    end
  end
end
