defmodule SymphonyElixir.RunLauncher.Kubernetes.PodWatch do
  @moduledoc """
  One watch over every runner pod, feeding an ETS cache the run watchers read.

  Without it each run's `SymphonyElixir.RunWatcher` GETs its pod every poll
  (5s): 200 requests a second at 1000 concurrent runs. With it the controller
  holds one list and one long-lived watch on
  `app.kubernetes.io/name=symphony-runner` pods in
  `agent.kubernetes.namespace`, and `SymphonyElixir.RunLauncher.Kubernetes.status/2`
  reads the pod from the cache (`lookup/2`).

  The watch loop, while the configured launcher is Kubernetes:

    1. List the pods (paged) and replace the cache with them; the list's
       `resourceVersion` is where the watch starts.
    2. Watch from that version, with bookmarks (`allowWatchBookmarks`), in a
       task; each batch of events updates the cache and the version.
    3. When the API server ends the watch (`timeoutSeconds`), watch again from
       the last version at once. A `410 Gone` (the version is too old) lists
       again. Any other error watches again after a backoff (1s, doubling to
       30s), and a failed list is retried the same way.

  The cache is trusted while it is synced and the watch has not been failing
  for longer than `stale_after_ms` (60s). A stale cache, or a pod missing from
  it (one just created, whose `ADDED` event has not arrived yet, or one that is
  gone), makes `status/2` fall back to a GET for that pod, so a watch outage
  degrades to the old polling instead of wrong answers.

  It also keeps the runner pod metrics (see `docs/durable-runs.md`): pods by
  phase and pods waiting for Kueue admission or a node (refreshed every
  `gauge_interval_ms`), the created-to-running latency and pod failures seen as
  transitions, and watch reconnects by reason.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Capacity.Metrics
  alias SymphonyElixir.Config
  alias SymphonyElixir.Kube
  alias SymphonyElixir.RunLauncher
  alias SymphonyElixir.RunLauncher.Kubernetes

  @table :symphony_runner_pod_cache
  @meta :__pod_watch_meta__
  @selector "app.kubernetes.io/name=symphony-runner"
  @check_interval_ms 30_000
  @gauge_interval_ms 5_000
  @stale_after_ms 60_000
  @min_backoff_ms 1_000
  @max_backoff_ms 30_000
  @phases ["Pending", "Running", "Succeeded", "Failed", "Unknown"]

  @type lookup :: {:ok, map()} | :miss | :stale

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The cached pod named `name` in `namespace`: `{:ok, pod}`, `:miss` when the
  synced cache has no such pod, or `:stale` when the cache cannot be trusted
  (no watch running, not synced yet, another namespace, or a watch that has
  been failing for longer than `stale_after_ms`).
  """
  @spec lookup(String.t(), String.t(), atom()) :: lookup()
  def lookup(namespace, name, table \\ @table) when is_binary(namespace) and is_binary(name) do
    with [{@meta, meta}] <- safe_lookup(table, @meta),
         true <- fresh?(meta, namespace) do
      case safe_lookup(table, name) do
        [{^name, pod}] -> {:ok, pod}
        _missing -> :miss
      end
    else
      _stale -> :stale
    end
  end

  @doc "Whether the cache is synced and fresh for `namespace`."
  @spec synced?(String.t(), atom()) :: boolean()
  def synced?(namespace, table \\ @table) do
    case safe_lookup(table, @meta) do
      [{@meta, meta}] -> fresh?(meta, namespace)
      _other -> false
    end
  end

  @doc "The table the cache lives in."
  @spec table() :: atom()
  def table, do: @table

  @impl true
  def init(opts) do
    # So terminate/2 runs on shutdown and stops the watch task with us.
    Process.flag(:trap_exit, true)
    table = Keyword.get(opts, :table, @table)

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])
    end

    state = %{
      opts: opts,
      table: table,
      active?: false,
      namespace: nil,
      client: nil,
      resource_version: nil,
      task: nil,
      watch_tag: nil,
      backoff_ms: min_backoff(opts),
      down_since_ms: nil,
      synced?: false,
      dirty?: false,
      retry_timer: nil
    }

    send(self(), :check)
    Process.send_after(self(), :refresh_gauges, option(opts, :gauge_interval_ms, @gauge_interval_ms))
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    Process.send_after(self(), :check, option(state.opts, :check_interval_ms, @check_interval_ms))
    {:noreply, check(state)}
  end

  def handle_info(:relist, %{active?: true} = state), do: {:noreply, relist(%{state | retry_timer: nil})}
  def handle_info(:rewatch, %{active?: true} = state), do: {:noreply, start_watch(%{state | retry_timer: nil})}

  def handle_info({:pod_events, tag, events}, %{watch_tag: tag} = state) when is_reference(tag) do
    {:noreply, Enum.reduce(events, state, &apply_event/2)}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, watch_ended(%{state | task: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, watch_ended(%{state | task: nil}, {:error, {:watch_crashed, reason}})}
  end

  def handle_info(:refresh_gauges, state) do
    Process.send_after(self(), :refresh_gauges, option(state.opts, :gauge_interval_ms, @gauge_interval_ms))
    {:noreply, refresh_gauges(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_task(state)
    :ok
  end

  # ------------------------------------------------------------ lifecycle

  defp check(state) do
    case {enabled?(state.opts), state.active?} do
      {true, false} -> activate(state)
      {false, true} -> deactivate(state)
      _unchanged -> state
    end
  end

  defp enabled?(opts) do
    case Keyword.fetch(opts, :enabled) do
      {:ok, enabled} when is_function(enabled, 0) -> enabled.() == true
      {:ok, enabled} -> enabled == true
      :error -> RunLauncher.launcher() == Kubernetes
    end
  end

  defp activate(state) do
    with {:ok, namespace} <- namespace(state.opts),
         {:ok, client} <- Kube.client(kube_options(state.opts)) do
      relist(%{state | active?: true, namespace: namespace, client: client, down_since_ms: now_ms()})
    else
      {:error, reason} ->
        Logger.warning("Runner pod watch could not start reason=#{inspect(reason, limit: 5)}")
        state
    end
  end

  defp deactivate(state) do
    state = stop_task(state)
    cancel_timer(state.retry_timer)
    :ets.delete_all_objects(state.table)
    Metrics.delete_gauges(["symphony_runner_pods", "symphony_runner_pods_waiting"])
    Metrics.set_gauge("symphony_runner_pod_watch_synced", [], 0)
    %{state | active?: false, synced?: false, resource_version: nil, retry_timer: nil, dirty?: false}
  end

  defp namespace(opts) do
    case Keyword.get(opts, :namespace) do
      namespace when is_binary(namespace) -> {:ok, namespace}
      nil -> with {:ok, settings} <- Config.settings(), do: {:ok, settings.agent.kubernetes.namespace}
    end
  end

  defp kube_options(opts), do: Keyword.take(opts, [:base_url, :token, :service_account_dir, :env, :req_options])

  # ------------------------------------------------------------ list and watch

  defp relist(state) do
    state = stop_task(state)

    case Kube.list_pods_with_version(state.client, state.namespace, @selector, list_options(state.opts)) do
      {:ok, pods, resource_version} ->
        replace_cache(state, pods)

        %{state | resource_version: resource_version, synced?: true, backoff_ms: min_backoff(state.opts), down_since_ms: nil, dirty?: true}
        |> write_meta()
        |> start_watch()

      {:error, reason} ->
        Logger.warning("Runner pod list failed reason=#{inspect(reason, limit: 5)}")
        reconnect_later(state, :relist, "list_" <> reason_label(reason))
    end
  end

  defp list_options(opts), do: Keyword.take(opts, [:limit])

  defp start_watch(state) do
    owner = self()
    %{client: client, namespace: namespace, resource_version: version} = state
    watch_options = Keyword.take(state.opts, [:timeout_seconds, :receive_timeout])
    # Events carry the watch's tag, so a replaced watch's late events are ignored.
    tag = make_ref()

    task =
      Task.Supervisor.async_nolink(task_supervisor(state.opts), fn ->
        Kube.watch_pods(client, namespace, @selector, version, &send(owner, {:pod_events, tag, &1}), watch_options)
      end)

    %{state | task: task, watch_tag: tag}
  end

  defp task_supervisor(opts), do: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor)

  defp watch_ended(state, {:ok, :closed}) do
    record_reconnect("closed")
    state |> Map.put(:backoff_ms, min_backoff(state.opts)) |> start_watch()
  end

  defp watch_ended(state, {:error, :gone}) do
    record_reconnect("gone")
    relist(state)
  end

  defp watch_ended(state, {:error, reason}) do
    Logger.warning("Runner pod watch failed reason=#{inspect(reason, limit: 5)}")
    reconnect_later(state, :rewatch, reason_label(reason))
  end

  defp reconnect_later(state, message, reason) do
    record_reconnect(reason)
    timer = Process.send_after(self(), message, state.backoff_ms)

    write_meta(%{
      state
      | retry_timer: timer,
        backoff_ms: min(state.backoff_ms * 2, @max_backoff_ms),
        down_since_ms: state.down_since_ms || now_ms()
    })
  end

  defp record_reconnect(reason), do: Metrics.record_counter("symphony_runner_pod_watch_reconnects_total", reason: reason)

  defp reason_label(:gone), do: "gone"
  defp reason_label(:not_found), do: "not_found"
  defp reason_label({:http_error, status, _body}) when is_integer(status), do: "http_#{status}"
  defp reason_label({:watch_error, _status}), do: "watch_error"
  defp reason_label({:invalid_watch_event, _line}), do: "invalid_event"
  defp reason_label({:watch_crashed, _reason}), do: "crashed"
  # A Req exception (connection refused, timeout, closed mid-stream).
  defp reason_label(_reason), do: "transport"

  defp stop_task(%{task: %Task{} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    %{state | task: nil, watch_tag: nil}
  end

  defp stop_task(state), do: state

  defp cancel_timer(timer) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_timer(_timer), do: :ok

  # ------------------------------------------------------------ cache

  defp replace_cache(state, pods) do
    fresh = Map.new(for pod <- pods, name = name(pod), is_binary(name), do: {name, trim(pod)})

    for {name, _pod} <- :ets.tab2list(state.table), name != @meta, not Map.has_key?(fresh, name) do
      :ets.delete(state.table, name)
    end

    Enum.each(fresh, fn {name, pod} -> put(state, name, pod) end)
  end

  defp apply_event(%{"type" => "BOOKMARK", "object" => object}, state), do: put_version(state, object)

  defp apply_event(%{"type" => type, "object" => object}, state) when type in ["ADDED", "MODIFIED"] do
    case name(object) do
      name when is_binary(name) -> put(state, name, trim(object))
      _no_name -> :ok
    end

    state |> put_version(object) |> Map.put(:dirty?, true) |> healthy()
  end

  defp apply_event(%{"type" => "DELETED", "object" => object}, state) do
    case name(object) do
      name when is_binary(name) -> :ets.delete(state.table, name)
      _no_name -> :ok
    end

    state |> put_version(object) |> Map.put(:dirty?, true) |> healthy()
  end

  defp apply_event(_event, state), do: state

  # An event proves the watch works again after a failure.
  defp healthy(%{down_since_ms: nil} = state), do: state
  defp healthy(state), do: write_meta(%{state | down_since_ms: nil, backoff_ms: min_backoff(state.opts)})

  defp put_version(state, object) do
    case get_in(object, ["metadata", "resourceVersion"]) do
      version when is_binary(version) and version != "" -> %{state | resource_version: version}
      _none -> state
    end
  end

  defp put(state, name, pod) do
    previous =
      case :ets.lookup(state.table, name) do
        [{^name, old}] -> old
        [] -> nil
      end

    :ets.insert(state.table, {name, pod})
    record_transition(previous, pod)
  end

  defp write_meta(state) do
    :ets.insert(state.table, {@meta, %{namespace: state.namespace, synced?: state.synced?, down_since_ms: state.down_since_ms, stale_after_ms: option(state.opts, :stale_after_ms, @stale_after_ms)}})
    state
  end

  defp fresh?(%{namespace: namespace, synced?: true, down_since_ms: nil}, namespace), do: true

  defp fresh?(%{namespace: namespace, synced?: true, down_since_ms: since, stale_after_ms: stale_after}, namespace)
       when is_integer(since),
       do: now_ms() - since < stale_after

  defp fresh?(_meta, _namespace), do: false

  defp safe_lookup(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> []
  end

  # Only what the watchers, the janitor and the metrics read is kept, so 1000
  # pods stay a few megabytes.
  defp trim(pod) do
    metadata = Map.get(pod, "metadata", %{})
    spec = Map.get(pod, "spec", %{})

    %{
      "metadata" => Map.take(metadata, ["name", "namespace", "creationTimestamp", "deletionTimestamp", "resourceVersion"]),
      "spec" => Map.take(if(is_map(spec), do: spec, else: %{}), ["schedulingGates"]),
      "status" => Map.get(pod, "status", %{})
    }
  end

  defp name(pod), do: get_in(pod, ["metadata", "name"])

  # ------------------------------------------------------------ metrics

  defp record_transition(%{} = previous, pod) do
    case {Kubernetes.phase(previous), Kubernetes.phase(pod)} do
      {"Pending", "Running"} -> record_scheduling_latency(pod)
      {old, "Failed"} when old != "Failed" -> Metrics.record_counter("symphony_runner_pod_failures_total", reason: failure_label(pod))
      _other -> :ok
    end
  end

  defp record_transition(nil, _pod), do: :ok

  defp record_scheduling_latency(pod) do
    with created when is_integer(created) <- timestamp_ms(get_in(pod, ["metadata", "creationTimestamp"])),
         started when is_integer(started) <- running_since_ms(pod) do
      Metrics.record_histogram("symphony_runner_pod_start_seconds", [], max(started - created, 0) / 1_000)
    end

    :ok
  end

  # The runner container's start, else the pod's (the kubelet accepted it).
  defp running_since_ms(pod) do
    statuses = pod |> get_in(["status", "containerStatuses"]) |> List.wrap()

    runner_started =
      Enum.find_value(statuses, fn
        %{"name" => "runner", "state" => %{"running" => %{"startedAt" => started}}} -> timestamp_ms(started)
        _other -> nil
      end)

    runner_started || timestamp_ms(get_in(pod, ["status", "startTime"]))
  end

  # `OOMKilled (exit code 137)` counts as `OOMKilled`: exit codes and free
  # text would make the label unbounded.
  defp failure_label(pod) do
    {:gone, {:pod_failed, reason}} = Kubernetes.pod_status(pod)

    reason
    |> String.split(" (", parts: 2)
    |> hd()
    |> String.slice(0, 40)
  end

  defp refresh_gauges(%{active?: true, dirty?: true} = state) do
    pods = for {name, pod} <- :ets.tab2list(state.table), name != @meta, do: pod
    phases = Enum.frequencies_by(pods, &phase_label/1)

    for phase <- @phases do
      label = String.downcase(phase)
      Metrics.set_gauge("symphony_runner_pods", [phase: label], Map.get(phases, label, 0))
    end

    waiting = pods |> Enum.map(&waiting_reason/1) |> Enum.reject(&is_nil/1) |> Enum.frequencies()

    for reason <- ["scheduling_gated", "unschedulable"] do
      Metrics.set_gauge("symphony_runner_pods_waiting", [reason: reason], Map.get(waiting, reason, 0))
    end

    refresh_gauges(%{state | dirty?: false})
  end

  defp refresh_gauges(%{active?: true} = state) do
    Metrics.set_gauge("symphony_runner_pod_watch_synced", [], if(synced?(state.namespace, state.table), do: 1, else: 0))
    state
  end

  defp refresh_gauges(state), do: state

  defp phase_label(pod) do
    case Kubernetes.phase(pod) do
      phase when phase in @phases -> String.downcase(phase)
      _other -> "unknown"
    end
  end

  @doc false
  # Why a Pending pod is not running yet, when it is waiting for capacity:
  # Kueue's scheduling gate (not admitted) or no node that fits.
  @spec waiting_reason(map()) :: String.t() | nil
  def waiting_reason(pod) do
    cond do
      Kubernetes.phase(pod) != "Pending" -> nil
      get_in(pod, ["spec", "schedulingGates"]) not in [nil, []] -> "scheduling_gated"
      unschedulable?(pod) -> "unschedulable"
      true -> nil
    end
  end

  defp unschedulable?(pod) do
    pod
    |> get_in(["status", "conditions"])
    |> List.wrap()
    |> Enum.any?(&match?(%{"type" => "PodScheduled", "status" => "False", "reason" => "Unschedulable"}, &1))
  end

  defp timestamp_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      {:error, _reason} -> nil
    end
  end

  defp timestamp_ms(_value), do: nil

  defp option(opts, key, default), do: Keyword.get(opts, key, default)

  defp min_backoff(opts), do: option(opts, :min_backoff_ms, @min_backoff_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
