defmodule SymphonyElixir.RunTrace do
  @moduledoc """
  W3C trace context for one run: one trace from the controller's dispatch,
  through the runner, to the agent CLI's spans.

  A run's trace id and root span id are derived from its run id (a SHA-256
  prefix), so every process that knows the run id agrees on them without
  storing anything: a controller that restarts and adopts a live run keeps
  its trace, and a retry (a new run id) starts a new one.

  The spans:

    * `symphony.run` — the root, emitted by the controller when the run leaves
      `running` (its start is the run's `started_at`, which the run registry
      keeps across a restart).
    * `symphony.dispatch` — the controller starting the run through its
      launcher, a child of the root.
    * `symphony.agent_run` — `SymphonyElixir.AgentRunner.run/3`, wherever it
      runs (controller task, runner process, runner pod), a child of the root.
      The agent CLI gets `TRACEPARENT` naming this span, so a CLI that reads
      W3C context from its environment nests its spans under it.

  The run's resource attributes (`symphony.run.id`, `symphony.run.attempt`,
  `symphony.run.launcher`, `symphony.run.started_on`, `symphony.project`,
  `symphony.trace_id`) go on every Symphony span and into the agent's
  `OTEL_RESOURCE_ATTRIBUTES`, so a CLI that ignores `TRACEPARENT` can still be
  joined to its run. `symphony.run.started_on` is the run's start date in UTC
  as `YYYY/MM/DD`, from its `started_at` (kept by the run registry, so it is
  the same after a restart); the trace archive files a run's signals under it.

  The controller hands the context to a separate runner in the run spec's
  `telemetry` map (`to_spec_map/2`); `from_spec/1` reads it back.
  """

  alias SymphonyElixir.TraceExporter

  @pdict_key {__MODULE__, :current}
  @version "00"
  @sampled "01"

  defstruct [
    :trace_id,
    :span_id,
    :parent_span_id,
    :run_id,
    :attempt,
    :launcher,
    :started_on,
    :issue_id,
    :identifier,
    :project,
    :backend
  ]

  @type t :: %__MODULE__{
          trace_id: String.t(),
          span_id: String.t(),
          parent_span_id: String.t() | nil,
          run_id: String.t(),
          attempt: non_neg_integer() | nil,
          launcher: String.t() | nil,
          started_on: String.t() | nil,
          issue_id: String.t() | nil,
          identifier: String.t() | nil,
          project: String.t() | nil,
          backend: String.t() | nil
        }

  @doc "The run's 32-hex-digit trace id."
  @spec trace_id(String.t()) :: String.t()
  def trace_id(run_id) when is_binary(run_id), do: derived_id("symphony.trace", run_id, 16)

  @doc "The run's root (`symphony.run`) span id, 16 hex digits."
  @spec root_span_id(String.t()) :: String.t()
  def root_span_id(run_id) when is_binary(run_id), do: derived_id("symphony.run", run_id, 8)

  @doc "A random span id."
  @spec new_span_id() :: String.t()
  def new_span_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @doc "The `traceparent` header value for a context (its own span is the parent)."
  @spec traceparent(t()) :: String.t()
  def traceparent(%__MODULE__{trace_id: trace_id, span_id: span_id}), do: Enum.join([@version, trace_id, span_id, @sampled], "-")

  @doc "Parses a `traceparent` value into `{trace_id, span_id}`."
  @spec parse_traceparent(term()) :: {:ok, {String.t(), String.t()}} | :error
  def parse_traceparent(value) when is_binary(value) do
    case String.split(String.downcase(String.trim(value)), "-") do
      [version, trace_id, span_id, flags | _rest] when version != "ff" ->
        if hex?(version, 2) and hex?(trace_id, 32) and hex?(span_id, 16) and hex?(flags, 2) and
             trace_id != String.duplicate("0", 32) and span_id != String.duplicate("0", 16),
           do: {:ok, {trace_id, span_id}},
           else: :error

      _ ->
        :error
    end
  end

  def parse_traceparent(_value), do: :error

  @doc """
  The root context of a run: its trace and `symphony.run` span. `opts`:
  `:attempt`, `:launcher` (a launcher module or name), `:started_at` (the
  run's start, a `DateTime`), `:issue` (for its id, identifier and project
  slug), `:backend`.
  """
  @spec root(String.t(), keyword()) :: t()
  def root(run_id, opts \\ []) when is_binary(run_id) do
    issue = Keyword.get(opts, :issue) || %{}

    %__MODULE__{
      trace_id: trace_id(run_id),
      span_id: root_span_id(run_id),
      parent_span_id: nil,
      run_id: run_id,
      attempt: Keyword.get(opts, :attempt),
      launcher: launcher_name(Keyword.get(opts, :launcher)),
      started_on: started_on(Keyword.get(opts, :started_at)),
      issue_id: field(issue, :id),
      identifier: field(issue, :identifier),
      project: field(issue, :project_slug),
      backend: Keyword.get(opts, :backend)
    }
  end

  @doc "A start time's UTC date as `YYYY/MM/DD` (nil without one)."
  @spec started_on(DateTime.t() | nil) :: String.t() | nil
  def started_on(%DateTime{} = started_at), do: started_at |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y/%m/%d")
  def started_on(_started_at), do: nil

  @doc "A child of `parent` with a new span id."
  @spec child(t()) :: t()
  def child(%__MODULE__{} = parent), do: %{parent | parent_span_id: parent.span_id, span_id: new_span_id()}

  @doc "The short launcher name: `local`, `process`, `kubernetes`, or the module's last segment."
  @spec launcher_name(module() | String.t() | nil) :: String.t() | nil
  def launcher_name(nil), do: nil
  def launcher_name(name) when is_binary(name), do: name

  def launcher_name(module) when is_atom(module) do
    module |> Module.split() |> List.last() |> Macro.underscore()
  rescue
    ArgumentError -> to_string(module)
  end

  @doc """
  The run spec's `telemetry` map: the root `traceparent`, the launcher name,
  the run's start date (`started_on`), and the OTLP endpoint and protocol a runner should use instead of the
  configured ones (nil when it uses the configured ones). It never carries
  credentials: exporter authentication lives in the collector.
  """
  @spec to_spec_map(t(), %{endpoint: String.t(), protocol: String.t()} | nil) :: map()
  def to_spec_map(%__MODULE__{} = root, otlp_override \\ nil) do
    %{
      "traceparent" => traceparent(root),
      "launcher" => root.launcher,
      "started_on" => root.started_on,
      "otlp_endpoint" => otlp_override && otlp_override.endpoint,
      "otlp_protocol" => otlp_override && otlp_override.protocol
    }
  end

  @doc """
  The root context a runner continues, from its spec: the spec's
  `traceparent` when it has a valid one, else the context derived from the
  run id (a spec written before trace context was carried).
  """
  @spec from_spec(map()) :: t()
  def from_spec(%{run_id: run_id} = spec) when is_binary(run_id) do
    telemetry = Map.get(spec, :telemetry) || %{}
    root = root(run_id, attempt: Map.get(spec, :attempt), launcher: telemetry["launcher"], issue: Map.get(spec, :issue), backend: Map.get(spec, :backend))
    root = %{root | started_on: spec_started_on(telemetry["started_on"])}

    case parse_traceparent(telemetry["traceparent"]) do
      {:ok, {trace_id, span_id}} -> %{root | trace_id: trace_id, span_id: span_id}
      :error -> root
    end
  end

  @doc "The OTLP override in a spec's `telemetry` map, or nil."
  @spec spec_otlp_override(map() | nil) :: %{endpoint: String.t(), protocol: String.t()} | nil
  def spec_otlp_override(%{"otlp_endpoint" => endpoint} = telemetry) when is_binary(endpoint) and endpoint != "" do
    %{endpoint: endpoint, protocol: present(telemetry["otlp_protocol"]) || "http/protobuf"}
  end

  def spec_otlp_override(_telemetry), do: nil

  @doc "Makes `context` the current process's run context (nil clears it)."
  @spec put_current(t() | nil) :: :ok
  def put_current(nil) do
    Process.delete(@pdict_key)
    :ok
  end

  def put_current(%__MODULE__{} = context) do
    Process.put(@pdict_key, context)
    :ok
  end

  @doc "The current process's run context, or nil."
  @spec current() :: t() | nil
  def current, do: Process.get(@pdict_key)

  @doc "The run's resource attributes (string keys, nils left out)."
  @spec resource_attributes(t() | nil) :: %{String.t() => String.t()}
  def resource_attributes(nil), do: %{}

  def resource_attributes(%__MODULE__{} = context) do
    [
      {"symphony.run.id", context.run_id},
      {"symphony.run.attempt", context.attempt},
      {"symphony.run.launcher", context.launcher},
      {"symphony.run.started_on", context.started_on},
      {"symphony.project", context.project},
      {"symphony.trace_id", context.trace_id},
      {"linear.issue.id", context.issue_id},
      {"linear.issue.identifier", context.identifier},
      {"symphony.backend", context.backend}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new(fn {key, value} -> {key, to_string(value)} end)
  end

  @doc """
  Emits the span `context` names, from `started_at` until now. `status` is
  `:ok` or `{:error, message}`. Never raises: a span that cannot be emitted is
  dropped.
  """
  @spec emit(t() | nil, String.t(), DateTime.t() | integer(), :ok | {:error, String.t()}, map()) :: :ok
  def emit(context, name, started_at, status \\ :ok, attributes \\ %{})

  def emit(nil, _name, _started_at, _status, _attributes), do: :ok

  def emit(%__MODULE__{} = context, name, started_at, status, attributes) do
    TraceExporter.emit(%{
      trace_id: context.trace_id,
      span_id: context.span_id,
      parent_span_id: context.parent_span_id,
      name: name,
      start_ns: to_unix_ns(started_at),
      end_ns: System.os_time(:nanosecond),
      status: status,
      attributes: Map.merge(span_attributes(context, name), attributes),
      resource: resource_attributes(context)
    })
  rescue
    _error -> :ok
  end

  # Langfuse names the trace after its root and groups an issue's attempts
  # into one session.
  defp span_attributes(%__MODULE__{} = context, "symphony.run") do
    %{"langfuse.trace.name" => trace_name(context)}
    |> put_present("langfuse.session.id", context.identifier)
    |> put_present("session.id", context.identifier)
  end

  defp span_attributes(_context, _name), do: %{}

  defp trace_name(%__MODULE__{identifier: identifier, attempt: attempt}) do
    base = "symphony.run " <> (identifier || "unknown")
    if is_integer(attempt), do: base <> " attempt " <> Integer.to_string(attempt), else: base
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, to_string(value))

  defp to_unix_ns(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :nanosecond)
  defp to_unix_ns(nanoseconds) when is_integer(nanoseconds), do: nanoseconds

  # An all-zero prefix (invalid in W3C) has odds of 2^-64 or less; not handled.
  defp derived_id(prefix, run_id, bytes) do
    <<id::binary-size(bytes), _rest::binary>> = :crypto.hash(:sha256, prefix <> <<0>> <> run_id)
    Base.encode16(id, case: :lower)
  end

  defp spec_started_on(value) when is_binary(value), do: if(value =~ ~r|^\d{4}/\d{2}/\d{2}$|, do: value)
  defp spec_started_on(_value), do: nil

  defp hex?(value, length), do: byte_size(value) == length and value =~ ~r/^[0-9a-f]+$/

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
