defmodule SymphonyElixir.RunOutbox do
  @moduledoc """
  A runner's unacknowledged events.

  Fire-and-forget host calls append an event here; a sender posts batches of up
  to 100 to the controller every 200ms (or immediately once 50 are waiting).
  Every event is also appended to `<run dir>/outbox.jsonl`, so if the runner
  is killed its events can be replayed from the file when it starts again.

  The controller acknowledges with `applied_through`; events up to that seq are
  dropped. While the controller is unreachable the sender backs off up to 5
  seconds and keeps buffering, which is what lets a run outlive a controller
  restart. A `409` (a stale epoch, see `SymphonyElixir.RunToken`, or a run
  already finished) means this runner has been fenced: the outbox stops it
  with `{:shutdown, :stale_epoch}`. A `404` (the controller no longer has the
  run) fences it the same way, with `{:shutdown, :run_not_found}`.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.PrivateFile
  alias SymphonyElixir.RunEvents

  @batch_size 100
  @flush_after 50
  @flush_interval_ms 200
  @min_retry_ms 200
  @max_retry_ms 5_000
  @request_timeout_ms 5_000
  @heartbeat_interval_ms 30_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Points this outbox at its run. Events already in the outbox file are loaded
  first, so a crashed runner's unacknowledged events go out again.
  """
  @spec configure(keyword() | map()) :: :ok
  def configure(opts), do: GenServer.call(server(opts), {:configure, opts}, :infinity)

  @doc "Appends an event to the outbox, posting it with the next batch."
  @spec append(GenServer.server(), String.t(), term()) :: :ok
  def append(outbox, type, data) when is_binary(type) do
    GenServer.cast(outbox, {:append, type, data})
  end

  @doc "Appends an event to the named default outbox."
  @spec append(String.t(), term()) :: :ok
  def append(type, data) when is_binary(type), do: append(__MODULE__, type, data)

  @doc """
  Waits until every event has been acknowledged, or `timeout` passes.
  Returns `:ok` whether it emptied or not; callers use it before exiting.
  """
  @spec flush(non_neg_integer(), GenServer.server()) :: :ok
  def flush(timeout \\ 5_000, outbox \\ __MODULE__) do
    cond do
      is_pid(outbox) and Process.alive?(outbox) -> flush_call(outbox, timeout)
      is_atom(outbox) and Process.whereis(outbox) != nil -> flush_call(outbox, timeout)
      true -> :ok
    end
  end

  defp flush_call(outbox, timeout) do
    GenServer.call(outbox, :flush, timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  The reason of the `finished` event in a run dir's outbox file, or nil. The
  file keeps every event the runner appended, acknowledged or not, so this
  tells a restarted controller that a runner which died had already finished.
  """
  @spec finished_reason(Path.t() | nil) :: String.t() | nil
  def finished_reason(dir) do
    {events, _next_seq} = load_pending(outbox_path(dir, nil))

    Enum.find_value(events, fn
      %{type: "finished", data: data} -> event_reason(RunEvents.decode(data))
      _event -> nil
    end)
  end

  defp event_reason({:ok, %{reason: reason}}) when is_binary(reason), do: reason
  defp event_reason(_decoded), do: "finished"

  @impl true
  def init(opts) do
    state = %{
      config: nil,
      pending: [],
      next_seq: 1,
      timer: nil,
      heartbeat_timer: nil,
      retry_ms: @min_retry_ms,
      flush_waiters: []
    }

    if opts[:run_id], do: {:ok, configure_state(state, opts)}, else: {:ok, state}
  end

  @impl true
  def handle_call({:configure, opts}, _from, state) do
    {:reply, :ok, configure_state(state, opts)}
  end

  def handle_call(:flush, from, state) do
    if state.pending == [] and state.timer == nil do
      {:reply, :ok, state}
    else
      {:noreply, %{state | flush_waiters: [from | state.flush_waiters]}}
    end
  end

  @impl true
  def handle_cast({:append, type, _data}, %{config: nil} = state) do
    # A runner configures its outbox before its first host call; without a run
    # there is nowhere to send or persist the event.
    Logger.warning("Run outbox ignoring event before it is configured type=#{type}")
    {:noreply, state}
  end

  def handle_cast({:append, type, data}, state) do
    {:noreply, append_event(state, type, data)}
  end

  @impl true
  def handle_info(:send_batch, state) do
    state = %{state | timer: nil}

    if state.config == nil or state.pending == [] do
      {:noreply, reply_flushed(state)}
    else
      {:noreply, send_batch(state)}
    end
  end

  def handle_info(:heartbeat, %{config: %{run_id: run_id}} = state) when is_binary(run_id) do
    state =
      state
      |> append_event("heartbeat", %{run_id: run_id})
      |> schedule_heartbeat()

    {:noreply, state}
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp configure_state(state, opts) do
    config = %{
      run_id: fetch_opt(opts, :run_id),
      base_url: fetch_opt(opts, :base_url),
      token: fetch_opt(opts, :token),
      path: outbox_path(fetch_opt(opts, :dir), fetch_opt(opts, :run_id)),
      heartbeat_interval_ms: fetch_opt(opts, :heartbeat_interval_ms) || @heartbeat_interval_ms
    }

    {pending, next_seq} = load_pending(config.path)
    cancel_heartbeat(state.heartbeat_timer)

    state
    |> Map.merge(%{config: config, pending: pending, next_seq: next_seq, retry_ms: @min_retry_ms, timer: nil, heartbeat_timer: nil})
    |> schedule_heartbeat()
  end

  defp append_event(state, type, data) do
    event = %{seq: state.next_seq, type: type, data: RunEvents.encode(data)}

    state =
      %{state | pending: state.pending ++ [event], next_seq: state.next_seq + 1}
      |> persist(event)

    if length(state.pending) >= @flush_after do
      send_soon(state, 0)
    else
      send_soon(state, @flush_interval_ms)
    end
  end

  defp schedule_heartbeat(%{config: %{run_id: run_id, heartbeat_interval_ms: interval_ms}} = state)
       when is_binary(run_id) and is_integer(interval_ms) and interval_ms > 0 do
    %{state | heartbeat_timer: Process.send_after(self(), :heartbeat, interval_ms)}
  end

  defp schedule_heartbeat(state), do: state

  defp cancel_heartbeat(timer) when is_reference(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  defp cancel_heartbeat(_timer), do: :ok

  defp fetch_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp fetch_opt(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  defp fetch_opt(_opts, _key), do: nil

  defp outbox_path(nil, _run_id), do: nil
  defp outbox_path(dir, _run_id) when is_binary(dir), do: dir |> Path.join("outbox.jsonl") |> Path.expand()

  defp load_pending(nil), do: {[], 1}

  defp load_pending(path) do
    case File.read(path) do
      {:ok, body} ->
        events =
          body
          |> String.split("\n", trim: true)
          |> Enum.flat_map(&decode_line/1)

        next_seq = Enum.reduce(events, 1, fn event, acc -> max(acc, event.seq + 1) end)
        {events, next_seq}

      {:error, _reason} ->
        {[], 1}
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{"seq" => seq, "type" => type, "data" => data}}
      when is_integer(seq) and seq > 0 and is_binary(type) and is_binary(data) ->
        [%{seq: seq, type: type, data: data}]

      _ ->
        []
    end
  end

  defp persist(%{config: %{path: nil}} = state, _event), do: state

  defp persist(%{config: %{path: path}} = state, event) do
    line = Jason.encode!(%{seq: event.seq, type: event.type, data: event.data}) <> "\n"

    with :ok <- PrivateFile.ensure_private_dir(Path.dirname(path)),
         :ok <- File.write(path, line, [:append]) do
      :ok
    else
      {:error, reason} -> Logger.warning("Run outbox write failed path=#{path} reason=#{inspect(reason)}")
    end

    state
  end

  defp send_soon(%{timer: timer} = state, _delay) when is_reference(timer), do: state
  defp send_soon(state, delay), do: %{state | timer: Process.send_after(self(), :send_batch, delay)}

  defp send_batch(%{config: %{base_url: base_url, run_id: run_id, token: token}} = state) do
    batch = Enum.take(state.pending, @batch_size)
    url = String.trim_trailing(base_url || "", "/") <> "/runner/v1/runs/#{run_id}/events"

    request = [
      method: :post,
      url: url,
      headers: [{"authorization", "Bearer #{token}"}],
      json: %{events: Enum.map(batch, &%{seq: &1.seq, type: &1.type, data: &1.data})},
      receive_timeout: @request_timeout_ms,
      retry: false
    ]

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        state
        |> acknowledge(applied_through(body))
        |> after_success()

      {:ok, %Req.Response{status: 409}} ->
        Logger.warning("Runner fenced by controller: stale epoch run_id=#{run_id}")
        exit({:shutdown, :stale_epoch})

      {:ok, %Req.Response{status: 404}} ->
        # The controller no longer knows the run (it ended, or another run
        # replaced it): fenced, like a stale epoch.
        Logger.warning("Runner fenced by controller: unknown run run_id=#{run_id}")
        exit({:shutdown, :run_not_found})

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Run outbox post failed run_id=#{run_id} status=#{status}; retrying")
        retry(state)

      {:error, reason} ->
        Logger.warning("Run outbox post failed run_id=#{run_id} reason=#{inspect(reason, limit: 5)}; retrying")
        retry(state)
    end
  end

  defp applied_through(%{"applied_through" => seq}) when is_integer(seq), do: seq
  defp applied_through(body) when is_binary(body), do: body |> Jason.decode() |> applied_through()
  defp applied_through({:ok, body}), do: applied_through(body)
  defp applied_through(_body), do: nil

  defp acknowledge(state, nil), do: state

  defp acknowledge(state, applied_through) do
    %{state | pending: Enum.filter(state.pending, &(&1.seq > applied_through))}
  end

  defp after_success(%{pending: []} = state) do
    state
    |> Map.put(:retry_ms, @min_retry_ms)
    |> reply_flushed()
  end

  defp after_success(state) do
    %{state | retry_ms: @min_retry_ms}
    |> send_soon(@flush_interval_ms)
  end

  defp retry(state) do
    retry_ms = min(state.retry_ms * 2, @max_retry_ms)
    %{state | retry_ms: retry_ms} |> send_soon(retry_ms)
  end

  defp reply_flushed(%{flush_waiters: []} = state), do: state

  defp reply_flushed(%{flush_waiters: waiters} = state) do
    Enum.each(waiters, &GenServer.reply(&1, :ok))
    %{state | flush_waiters: []}
  end

  defp server(opts) when is_list(opts), do: Keyword.get(opts, :name) || __MODULE__

  defp server(opts) when is_map(opts) do
    Map.get(opts, :name) || Map.get(opts, "name") || __MODULE__
  end

  defp server(_opts), do: __MODULE__
end
