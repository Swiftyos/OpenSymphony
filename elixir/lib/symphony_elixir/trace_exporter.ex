defmodule SymphonyElixir.TraceExporter do
  @moduledoc """
  Exports Symphony's own spans (`SymphonyElixir.RunTrace`) as OTLP/HTTP JSON.

  Bounded so that tracing can never take the controller down:

    * `emit/1` never blocks and never raises. It writes the span to an ETS
      queue, not to this process's mailbox, so a slow or dead collector cannot
      grow a mailbox.
    * The queue holds at most `telemetry.span_max_queue_size` spans (2048);
      a span emitted while it is full is dropped and counted.
    * Every `telemetry.span_export_interval_ms` (5 s) this process posts up to
      `telemetry.span_max_batch_size` spans (512) per request, each request
      bounded by `telemetry.span_export_timeout_ms` (5 s), with no retries. A
      failed batch is dropped and counted, not re-queued.

  Spans are exported only while `telemetry.enabled`, `telemetry.include_traces`
  and `telemetry.symphony_spans` are all true, to the traces endpoint
  `traces_endpoint/0` resolves. Symphony's exporter speaks OTLP/HTTP only: with
  a `grpc` protocol (and no HTTP traces endpoint) its spans are dropped and a
  warning is logged once. The limits are read when the exporter starts.

  `stats/0` returns `%{queued, dropped, exported, failed_batches}`.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, Telemetry}

  @queued 1
  @dropped 2
  @exported 3
  @failed 4

  @defaults %{max_queue_size: 2048, max_batch_size: 512, interval_ms: 5_000, timeout_ms: 5_000}

  @type span :: %{
          required(:trace_id) => String.t(),
          required(:span_id) => String.t(),
          required(:parent_span_id) => String.t() | nil,
          required(:name) => String.t(),
          required(:start_ns) => integer(),
          required(:end_ns) => integer(),
          required(:status) => :ok | {:error, String.t()},
          required(:attributes) => map(),
          required(:resource) => map()
        }

  @doc """
  Starts the exporter. Options (each overrides the config): `:name`,
  `:max_queue_size`, `:max_batch_size`, `:interval_ms`, `:timeout_ms`,
  `:req_options` (extra `Req` options, such as `:plug` in tests).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Queues a span for export; drops it when the queue is full or export is off."
  @spec emit(span(), GenServer.name()) :: :ok
  def emit(span, server \\ __MODULE__) when is_map(span) do
    with %{table: table, counters: counters, max_queue_size: max} <- lookup(server),
         true <- enabled?() do
      if :counters.get(counters, @queued) >= max do
        :counters.add(counters, @dropped, 1)
      else
        :counters.add(counters, @queued, 1)
        :ets.insert(table, {System.unique_integer([:monotonic, :positive]), span})
      end
    end

    :ok
  rescue
    _error -> :ok
  end

  @doc "Exports everything queued now, waiting at most `timeout_ms`. Never raises."
  @spec flush(non_neg_integer(), GenServer.name()) :: :ok
  def flush(timeout_ms \\ 10_000, server \\ __MODULE__) do
    GenServer.call(server, :flush, timeout_ms)
  catch
    :exit, _reason -> :ok
  end

  @doc "Queue and export counters."
  @spec stats(GenServer.name()) :: %{queued: non_neg_integer(), dropped: non_neg_integer(), exported: non_neg_integer(), failed_batches: non_neg_integer()}
  def stats(server \\ __MODULE__) do
    case lookup(server) do
      %{counters: counters} ->
        %{
          queued: :counters.get(counters, @queued),
          dropped: :counters.get(counters, @dropped),
          exported: :counters.get(counters, @exported),
          failed_batches: :counters.get(counters, @failed)
        }

      nil ->
        %{queued: 0, dropped: 0, exported: 0, failed_batches: 0}
    end
  end

  @doc """
  Where Symphony's spans go: the run's OTLP override (a runner pod), else
  `telemetry.otlp_traces_endpoint` as given, else `telemetry.otlp_endpoint`
  plus `/v1/traces`. Nil when the resolved protocol is `grpc` or there is no
  endpoint.
  """
  @spec traces_endpoint() :: String.t() | nil
  def traces_endpoint do
    case {Telemetry.otlp_override(), Config.settings()} do
      {%{endpoint: endpoint, protocol: protocol}, _settings} ->
        http_endpoint(protocol, signal_url(endpoint))

      {nil, {:ok, %{telemetry: telemetry}}} ->
        protocol = present(telemetry.otlp_traces_protocol) || telemetry.otlp_protocol

        cond do
          endpoint = present(telemetry.otlp_traces_endpoint) -> http_endpoint(protocol, endpoint)
          endpoint = present(telemetry.otlp_endpoint) -> http_endpoint(protocol, signal_url(endpoint))
          true -> nil
        end

      {nil, _error} ->
        nil
    end
  end

  @doc "The OTLP/JSON `ExportTraceServiceRequest` body for spans (grouped by resource)."
  @spec request_body([span()], map()) :: map()
  def request_body(spans, base_resource) do
    resource_spans =
      spans
      |> Enum.group_by(&Map.get(&1, :resource, %{}))
      |> Enum.map(fn {resource, group} ->
        %{
          "resource" => %{"attributes" => attributes(Map.merge(base_resource, resource))},
          "scopeSpans" => [%{"scope" => %{"name" => "symphony"}, "spans" => Enum.map(group, &otlp_span/1)}]
        }
      end)

    %{"resourceSpans" => resource_spans}
  end

  @impl true
  def init(opts) do
    limits = limits(opts)
    table = :ets.new(__MODULE__, [:ordered_set, :public, write_concurrency: true])
    counters = :counters.new(4, [:write_concurrency])
    name = Keyword.get(opts, :name, __MODULE__)
    :persistent_term.put({__MODULE__, name}, %{table: table, counters: counters, max_queue_size: limits.max_queue_size})
    Process.flag(:trap_exit, true)

    state = Map.merge(limits, %{name: name, table: table, counters: counters, req_options: Keyword.get(opts, :req_options), warned: false})
    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:export, state), do: {:noreply, state |> export_all() |> schedule()}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, export_all(state)}

  @impl true
  def terminate(_reason, state) do
    _ = export_all(state)
    :persistent_term.erase({__MODULE__, state.name})
    :ok
  end

  defp schedule(state) do
    Process.send_after(self(), :export, state.interval_ms)
    state
  end

  defp export_all(state) do
    case take(state, state.max_batch_size) do
      [] ->
        state

      spans ->
        state = export_batch(state, spans)
        if length(spans) == state.max_batch_size, do: export_all(state), else: state
    end
  end

  defp take(state, count) do
    case :ets.select(state.table, [{{:"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}], count) do
      {rows, _continuation} ->
        Enum.each(rows, fn {key, _span} -> :ets.delete(state.table, key) end)
        :counters.sub(state.counters, @queued, length(rows))
        Enum.map(rows, &elem(&1, 1))

      :"$end_of_table" ->
        []
    end
  end

  defp export_batch(state, spans) do
    case safe_endpoint() do
      nil ->
        :counters.add(state.counters, @dropped, length(spans))
        warn_once(state)

      endpoint ->
        post(state, endpoint, spans)
        state
    end
  end

  defp post(state, endpoint, spans) do
    request =
      [
        url: endpoint,
        json: request_body(spans, base_resource()),
        receive_timeout: state.timeout_ms,
        connect_options: [timeout: state.timeout_ms],
        retry: false
      ] ++ (state.req_options || req_options())

    case Req.post(request) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :counters.add(state.counters, @exported, length(spans))

      other ->
        Logger.debug("Trace export failed spans=#{length(spans)} result=#{inspect(other, limit: 5)}")
        :counters.add(state.counters, @failed, 1)
        :counters.add(state.counters, @dropped, length(spans))
    end
  rescue
    error ->
      Logger.debug("Trace export failed spans=#{length(spans)} error=#{Exception.message(error)}")
      :counters.add(state.counters, @failed, 1)
      :counters.add(state.counters, @dropped, length(spans))
  end

  defp warn_once(%{warned: true} = state), do: state

  defp warn_once(state) do
    if enabled?() do
      Logger.warning("Symphony spans are not exported: telemetry has no OTLP/HTTP traces endpoint (set otlp_protocol http/protobuf or otlp_traces_endpoint)")
      %{state | warned: true}
    else
      state
    end
  end

  defp safe_endpoint, do: if(enabled?(), do: traces_endpoint())

  defp enabled? do
    case Config.settings() do
      {:ok, %{telemetry: telemetry}} -> telemetry.enabled and telemetry.include_traces and telemetry.symphony_spans
      _error -> false
    end
  end

  defp base_resource do
    component = if Application.get_env(:symphony_elixir, :app_mode) == :runner, do: "runner", else: "controller"

    Config.telemetry_resource_attributes()
    |> Map.merge(%{"service.name" => "symphony", "symphony.component" => component})
    |> put_present("symphony.instance", Config.instance_name())
  end

  defp limits(opts) do
    configured =
      case Config.settings() do
        {:ok, %{telemetry: telemetry}} ->
          %{
            max_queue_size: telemetry.span_max_queue_size,
            max_batch_size: telemetry.span_max_batch_size,
            interval_ms: telemetry.span_export_interval_ms,
            timeout_ms: telemetry.span_export_timeout_ms
          }

        _error ->
          @defaults
      end

    Map.new(@defaults, fn {key, _default} -> {key, Keyword.get(opts, key, configured[key])} end)
  end

  defp req_options, do: Application.get_env(:symphony_elixir, :trace_exporter_req_options, [])

  defp lookup(server), do: :persistent_term.get({__MODULE__, server}, nil)

  defp otlp_span(span) do
    %{
      "traceId" => span.trace_id,
      "spanId" => span.span_id,
      "name" => span.name,
      # SPAN_KIND_INTERNAL
      "kind" => 1,
      "startTimeUnixNano" => Integer.to_string(span.start_ns),
      "endTimeUnixNano" => Integer.to_string(max(span.end_ns, span.start_ns)),
      "attributes" => attributes(span.attributes),
      "status" => status(span.status)
    }
    |> put_present("parentSpanId", span.parent_span_id)
  end

  defp status(:ok), do: %{"code" => 1}
  defp status({:error, message}), do: %{"code" => 2, "message" => to_string(message)}

  defp attributes(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> %{"key" => to_string(key), "value" => attribute_value(value)} end)
  end

  defp attribute_value(value) when is_boolean(value), do: %{"boolValue" => value}
  defp attribute_value(value) when is_integer(value), do: %{"intValue" => Integer.to_string(value)}
  defp attribute_value(value) when is_float(value), do: %{"doubleValue" => value}
  defp attribute_value(value), do: %{"stringValue" => to_string(value)}

  defp http_endpoint(protocol, endpoint) when protocol in ["http/protobuf", "http/json"], do: endpoint
  defp http_endpoint(_protocol, _endpoint), do: nil

  defp signal_url(endpoint), do: String.trim_trailing(endpoint, "/") <> "/v1/traces"

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
