defmodule SymphonyElixir.RunLauncher.Kubernetes do
  @moduledoc """
  Starts each run as a runner pod on Kubernetes (`agent.launcher: kubernetes`).

  `start_process/2` renders the run's Secret, ConfigMap and pod (see
  `SymphonyElixir.RunLauncher.Kubernetes.PodSpec`), creates the Secret and the
  ConfigMap, then the pod, and returns a `SymphonyElixir.RunWatcher` and the
  reference `"k8s:<namespace>/<pod>"`. The orchestrator monitors the watcher
  exactly like a process run's, so a pod's end reaches it the same way:

  - The runner's `finished` event (over `/runner/v1`) ends the watcher with
    the run's reason.
  - A pod that reaches a terminal phase, or disappears, without one ends it,
    after the watcher's grace period, with `{:pod_failed, reason}` (the pod's
    reason, else the runner container's terminated reason and exit code) or
    `:runner_lost`.
  - A 401/403 that lasts five minutes ends it with
    `{:pod_monitor_unauthorized, reason}`; other API errors are retried.

  A Pending pod is never timed out: Kueue may hold it behind its scheduling
  gate for as long as the queue is full. `activeDeadlineSeconds` still bounds
  a pod once it starts.

  Other details:

  - The ConfigMap holds the controller's effective config file (`symphony.yml`
    or `WORKFLOW.md`), which the runner is started with.
  - A Secret or ConfigMap left over from a crashed attempt (`409`) is deleted
    and created again.
  - Once the pod exists, the Secret and ConfigMap get an ownerReference to it,
    so the garbage collector removes them with the pod even if this controller
    restarts before cleaning up.
  - When the pod create fails without an answer (a timeout), the pod is read
    back before anything is cleaned up: it may have been created.
  - `release/1` (a run that ended) deletes the Secret and ConfigMap and keeps
    the pod for its logs; `stop/1` deletes the pod too unless it has already
    finished. `SymphonyElixir.RunLauncher.Kubernetes.Janitor` deletes finished
    pods after `agent.kubernetes.finished_pod_retention_ms`.
  """

  @behaviour SymphonyElixir.RunLauncher

  require Logger

  alias SymphonyElixir.Capacity.Metrics
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Kube
  alias SymphonyElixir.RunLauncher.Kubernetes.PodSpec
  alias SymphonyElixir.RunLauncher.Kubernetes.PodWatch
  alias SymphonyElixir.RunSpec
  alias SymphonyElixir.RunWatcher
  alias SymphonyElixir.SymphonyConfig
  alias SymphonyElixir.Workflow

  @prefix "k8s:"
  @terminal_phases ["Succeeded", "Failed"]

  @doc """
  Starts the run's Secret, ConfigMap, pod and watcher.

  Options: `:settings` (defaults to the loaded config), `:config_path` (the
  config file handed to the runner; defaults to the controller's own
  `symphony.yml` or `WORKFLOW.md`), the watcher's `:poll_interval_ms`,
  `:lost_grace_ms` and `:unauthorized_timeout_ms`, and any
  `SymphonyElixir.Kube` options (`:base_url`, `:token`,
  `:service_account_dir`, `:req_options`), which the watcher's pod checks use
  too.
  """
  @impl true
  @spec start_process(RunSpec.t(), keyword()) :: {:ok, pid(), String.t()} | {:error, term()}
  def start_process(%RunSpec{} = spec, opts \\ []) do
    with {:ok, settings} <- settings(opts),
         {:ok, runner_config} <- runner_config(opts),
         {:ok, rendered} <- PodSpec.render(spec, settings, runner_config),
         {:ok, client} <- Kube.client(opts),
         :ok <- create_run_objects(rendered, client),
         {:ok, watcher} <- start_watcher(spec, rendered, opts) do
      Logger.info("Started runner pod run_id=#{spec.run_id} ref=#{rendered.ref} watcher=#{inspect(watcher)}")
      Metrics.record_counter("symphony_runner_launches_total", outcome: "started")
      {:ok, watcher, rendered.ref}
    else
      {:error, reason} = error ->
        Logger.error("Unable to start runner pod run_id=#{spec.run_id} reason=#{inspect(reason, limit: 10)}")
        Metrics.record_counter("symphony_runner_launches_total", outcome: "failed")
        Metrics.record_counter("symphony_runner_launch_failures_total", reason: launch_failure_reason(reason))
        error
    end
  end

  @doc false
  # A bounded label for why a launch failed: the step, or the API's HTTP
  # status, never the free-text error.
  @spec launch_failure_reason(term()) :: String.t()
  def launch_failure_reason({:invalid_settings, _settings}), do: "settings"
  def launch_failure_reason({:runner_config, _path, _reason}), do: "runner_config"
  def launch_failure_reason({:watcher_failed, _reason}), do: "watcher"
  def launch_failure_reason({:http_error, status, _body}) when is_integer(status), do: "http_#{status}"
  def launch_failure_reason(:not_in_cluster), do: "kube_client"
  def launch_failure_reason({:in_cluster_config, _reason}), do: "kube_client"
  def launch_failure_reason(%{__exception__: true}), do: "transport"
  def launch_failure_reason(reason) when is_atom(reason), do: "render"
  def launch_failure_reason({reason, _detail}) when is_atom(reason), do: "render"
  def launch_failure_reason(_reason), do: "other"

  @doc "The behaviour's `start/2`: a run spec (or `%{spec: spec}`) is started as a pod."
  @impl true
  @spec start(term(), keyword()) :: {:ok, pid(), String.t()} | {:error, term()}
  def start(%RunSpec{} = spec, opts), do: start_process(spec, opts)
  def start(%{spec: %RunSpec{} = spec}, opts), do: start_process(spec, opts)
  def start(_fun_or_other, _opts), do: {:error, :missing_run_spec}

  @doc "The controller URL runner pods use: `agent.kubernetes.controller_url`."
  @impl true
  @spec controller_url(Schema.t()) :: String.t() | nil
  def controller_url(%Schema{} = settings), do: settings.agent.kubernetes.controller_url

  @doc "The collector runner pods export to: `agent.kubernetes.otlp_endpoint`, or nil."
  @impl true
  @spec otlp_override(Schema.t()) :: %{endpoint: String.t(), protocol: String.t()} | nil
  def otlp_override(%Schema{agent: %{kubernetes: %{otlp_endpoint: endpoint} = kube}}) when is_binary(endpoint),
    do: %{endpoint: endpoint, protocol: kube.otlp_protocol}

  def otlp_override(%Schema{}), do: nil

  @doc "Whether the pod named by a reference exists and is Pending or Running."
  @impl true
  @spec alive?(String.t()) :: boolean()
  def alive?(ref), do: status(ref) == :alive

  @doc """
  The run's status from its pod: `:alive` while Pending or Running, `{:gone,
  nil}` when it Succeeded or is missing, `{:gone, {:pod_failed, reason}}` when
  it Failed, `{:unauthorized, reason}` for a 401/403 (or no usable
  credentials), and `{:unknown, reason}` for any other error or a phase that
  is not known yet (`Unknown`, or none).

  The pod is read from `SymphonyElixir.RunLauncher.Kubernetes.PodWatch`'s
  cache; only a pod missing from it, or a cache that is not synced or has
  gone stale, is fetched from the API server.
  """
  @impl true
  @spec status(String.t()) :: SymphonyElixir.RunLauncher.status()
  def status(ref), do: status(ref, [])

  @doc "`status/1` with explicit `SymphonyElixir.Kube` options."
  @spec status(String.t(), keyword()) :: SymphonyElixir.RunLauncher.status()
  def status(ref, opts) when is_binary(ref) do
    case parse_ref(ref) do
      {:ok, namespace, name} ->
        case PodWatch.lookup(namespace, name, Keyword.get(opts, :pod_cache, PodWatch.table())) do
          {:ok, pod} ->
            record_status_check("cache")
            pod_status(pod)

          miss_or_stale ->
            record_status_check(Atom.to_string(miss_or_stale))
            fetch_status(namespace, name, opts)
        end

      :error ->
        {:gone, nil}
    end
  end

  def status(_ref, _opts), do: {:gone, nil}

  defp fetch_status(namespace, name, opts) do
    case client(opts) do
      {:ok, client} ->
        case Kube.get_pod(client, namespace, name) do
          {:ok, pod} -> pod_status(pod)
          {:error, :not_found} -> {:gone, nil}
          {:error, {:http_error, status, _body} = reason} when status in [401, 403] -> {:unauthorized, reason}
          {:error, reason} -> {:unknown, reason}
        end

      {:error, reason} ->
        {:unauthorized, reason}
    end
  end

  defp record_status_check(source), do: Metrics.record_counter("symphony_runner_pod_status_checks_total", source: source)

  @doc """
  Deletes the pod (unless it has already finished, so its logs stay), its
  Secret and its ConfigMap; missing objects are not an error.
  """
  @impl true
  @spec stop(String.t()) :: :ok
  def stop(ref) when is_binary(ref) do
    with {:ok, namespace, name} <- parse_ref(ref),
         {:ok, client} <- Kube.client() do
      unless finished_pod?(client, namespace, name), do: _ = Kube.delete_pod(client, namespace, name)
      delete_run_objects(client, namespace, name)
    end

    :ok
  end

  def stop(_ref), do: :ok

  @doc """
  Deletes an ended run's Secret (the run token) and ConfigMap; the pod is kept
  for its logs until the janitor removes it.
  """
  @impl true
  @spec release(String.t()) :: :ok
  def release(ref) when is_binary(ref) do
    with {:ok, namespace, name} <- parse_ref(ref),
         {:ok, client} <- Kube.client() do
      delete_run_objects(client, namespace, name)
    end

    :ok
  end

  def release(_ref), do: :ok

  @doc "The pod's phase, or nil."
  @spec phase(map()) :: String.t() | nil
  def phase(%{"status" => %{"phase" => phase}}) when is_binary(phase), do: phase
  def phase(_pod), do: nil

  @doc "Whether a pod has reached a terminal phase."
  @spec terminal?(map()) :: boolean()
  def terminal?(pod), do: phase(pod) in @terminal_phases

  defp client(opts) do
    case Keyword.take(opts, [:base_url, :token, :service_account_dir, :env, :req_options]) do
      [] -> Kube.client()
      kube_opts -> Kube.client(kube_opts)
    end
  end

  @doc false
  @spec pod_status(map()) :: SymphonyElixir.RunLauncher.status()
  def pod_status(pod) do
    case phase(pod) do
      phase when phase in ["Pending", "Running"] -> :alive
      "Succeeded" -> {:gone, nil}
      "Failed" -> {:gone, {:pod_failed, failure_reason(pod)}}
      phase -> {:unknown, {:pod_phase, phase}}
    end
  end

  defp finished_pod?(client, namespace, name) do
    case Kube.get_pod(client, namespace, name) do
      {:ok, pod} -> terminal?(pod)
      _other -> false
    end
  end

  defp delete_run_objects(client, namespace, name) do
    for {kind, result} <- [
          secret: Kube.delete_secret(client, namespace, name),
          config_map: Kube.delete_config_map(client, namespace, name)
        ],
        not match?({:ok, _response}, result) and result != {:error, :not_found} do
      Logger.warning("Runner #{kind} cleanup failed run=#{@prefix}#{namespace}/#{name} reason=#{inspect(elem(result, 1), limit: 5)}")
    end

    :ok
  end

  defp start_watcher(spec, rendered, opts) do
    kube_opts = Keyword.take(opts, [:base_url, :token, :service_account_dir, :env, :req_options, :pod_cache])

    watcher_opts =
      [launcher: __MODULE__, status: fn -> status(rendered.ref, kube_opts) end] ++
        Keyword.take(opts, [:poll_interval_ms, :lost_grace_ms, :unauthorized_timeout_ms])

    case RunWatcher.start(%{run_id: spec.run_id, issue_id: issue_id(spec)}, rendered.ref, watcher_opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        # Without a watcher nothing would ever notice the pod's end.
        stop_with(rendered, kube_opts)
        {:error, {:watcher_failed, reason}}
    end
  end

  defp stop_with(rendered, kube_opts) do
    with {:ok, client} <- client(kube_opts) do
      _ = Kube.delete_pod(client, rendered.namespace, rendered.name)
      delete_run_objects(client, rendered.namespace, rendered.name)
    end
  end

  defp issue_id(%RunSpec{issue: issue}) when is_map(issue), do: Map.get(issue, :id) || Map.get(issue, "id")
  defp issue_id(_spec), do: nil

  defp settings(opts) do
    case Keyword.get(opts, :settings) do
      %Schema{} = settings -> {:ok, settings}
      nil -> Config.settings()
      other -> {:error, {:invalid_settings, other}}
    end
  end

  # The runner boots the same config as the controller. The ConfigMap key keeps
  # the extension, which is how `symphony runner` picks symphony.yml (global)
  # or WORKFLOW.md (legacy) mode.
  defp runner_config(opts) do
    path = Keyword.get_lazy(opts, :config_path, &controller_config_path/0)

    case File.read(path) do
      {:ok, content} -> {:ok, %{file_name: config_file_name(path), content: content}}
      {:error, reason} -> {:error, {:runner_config, path, reason}}
    end
  end

  defp controller_config_path do
    if Config.global_mode?(), do: SymphonyConfig.config_file_path(), else: Workflow.workflow_file_path()
  end

  defp config_file_name(path) do
    if String.downcase(Path.extname(path)) == ".md", do: "WORKFLOW.md", else: "symphony.yml"
  end

  defp create_run_objects(rendered, client) do
    with :ok <- create_replacing(client, rendered, :secret),
         :ok <- create_replacing(client, rendered, :config_map) do
      case create_pod(client, rendered) do
        {:ok, pod} ->
          own_run_objects(client, rendered, pod)
          :ok

        {:error, reason} ->
          cleanup_run_objects(rendered, client)
          {:error, reason}
      end
    else
      {:error, reason} ->
        cleanup_run_objects(rendered, client)
        {:error, reason}
    end
  end

  # A Secret or ConfigMap with this run's name is left from an attempt that
  # crashed between creating it and the pod. It belongs to the same run id, so
  # it is replaced rather than treated as a conflict.
  defp create_replacing(client, rendered, kind) do
    case create(client, rendered, kind) do
      {:ok, _object} ->
        :ok

      {:error, {:http_error, 409, _body}} ->
        Logger.info("Replacing leftover runner #{kind} run=#{rendered.ref}")

        with {:ok, _deleted} <- delete(client, rendered, kind),
             {:ok, _object} <- create(client, rendered, kind) do
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create(client, rendered, :secret), do: Kube.create_secret(client, rendered.namespace, rendered.secret)
  defp create(client, rendered, :config_map), do: Kube.create_config_map(client, rendered.namespace, rendered.config_map)

  defp delete(client, rendered, :secret), do: Kube.delete_secret(client, rendered.namespace, rendered.name)
  defp delete(client, rendered, :config_map), do: Kube.delete_config_map(client, rendered.namespace, rendered.name)

  # A rejection (an HTTP status) means no pod. Anything else, such as a
  # timeout, may have created it, so read it back before cleaning up.
  defp create_pod(client, rendered) do
    case Kube.create_pod(client, rendered.namespace, rendered.pod) do
      {:ok, pod} ->
        {:ok, pod}

      {:error, {:http_error, _status, _body}} = error ->
        error

      {:error, reason} ->
        recover_pod_create(client, rendered, reason)
    end
  end

  defp recover_pod_create(client, rendered, reason) do
    case Kube.get_pod(client, rendered.namespace, rendered.name) do
      {:ok, pod} ->
        Logger.warning("Runner pod create returned an error but the pod exists run=#{rendered.ref} reason=#{inspect(reason, limit: 5)}")
        {:ok, pod}

      {:error, :not_found} ->
        {:error, reason}

      {:error, _get_reason} ->
        # Unknown either way: remove a pod that might exist, so it cannot start
        # without its Secret, and report the original error.
        _ = Kube.delete_pod(client, rendered.namespace, rendered.name)
        {:error, reason}
    end
  end

  # Garbage collection then deletes the Secret and ConfigMap with the pod, so
  # they don't outlive it when this controller restarts before cleaning up.
  defp own_run_objects(client, rendered, %{"metadata" => %{"uid" => uid}}) when is_binary(uid) and uid != "" do
    patch = %{
      "metadata" => %{
        "ownerReferences" => [
          %{"apiVersion" => "v1", "kind" => "Pod", "name" => rendered.name, "uid" => uid}
        ]
      }
    }

    for {kind, result} <- [
          secret: Kube.patch_secret(client, rendered.namespace, rendered.name, patch),
          config_map: Kube.patch_config_map(client, rendered.namespace, rendered.name, patch)
        ],
        not match?({:ok, _object}, result) do
      Logger.warning("Runner #{kind} ownerReference failed run=#{rendered.ref} reason=#{inspect(elem(result, 1), limit: 5)}")
    end

    :ok
  end

  defp own_run_objects(_client, rendered, _pod) do
    Logger.warning("Runner pod has no uid; its Secret and ConfigMap get no ownerReference run=#{rendered.ref}")
    :ok
  end

  defp cleanup_run_objects(rendered, client), do: delete_run_objects(client, rendered.namespace, rendered.name)

  # The pod's own reason (DeadlineExceeded, Evicted) wins; otherwise the runner
  # container's terminated state says why it stopped.
  defp failure_reason(%{"status" => %{"reason" => reason}}) when is_binary(reason) and reason != "", do: reason

  defp failure_reason(%{"status" => %{"containerStatuses" => statuses}}) when is_list(statuses) do
    case Enum.find(statuses, &(is_map(&1) and &1["name"] == "runner")) do
      %{"state" => %{"terminated" => %{} = terminated}} -> terminated_reason(terminated)
      _other -> "failed"
    end
  end

  defp failure_reason(_pod), do: "failed"

  defp terminated_reason(terminated) do
    reason =
      case terminated["reason"] do
        reason when is_binary(reason) and reason != "" -> reason
        _other -> "failed"
      end

    case terminated["exitCode"] do
      code when is_integer(code) -> "#{reason} (exit code #{code})"
      _other -> reason
    end
  end

  defp parse_ref(@prefix <> rest) do
    case String.split(rest, "/", parts: 2) do
      [namespace, name] when namespace != "" and name != "" -> {:ok, namespace, name}
      _ -> :error
    end
  end

  defp parse_ref(_ref), do: :error
end
