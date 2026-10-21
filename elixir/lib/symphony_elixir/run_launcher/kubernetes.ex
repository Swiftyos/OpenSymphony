defmodule SymphonyElixir.RunLauncher.Kubernetes do
  @moduledoc """
  Starts each run as a runner pod on Kubernetes.

  `start/2` renders the run's Secret, ConfigMap and pod (see
  `SymphonyElixir.RunLauncher.Kubernetes.PodSpec`), creates the Secret and the
  ConfigMap, then the pod, and returns a lightweight monitor process and the
  reference `"k8s:<namespace>/<pod>"`.

  - The ConfigMap holds the controller's effective config file (`symphony.yml`
    or `WORKFLOW.md`), which the runner is started with.
  - A Secret or ConfigMap left over from a crashed attempt (`409`) is deleted
    and created again.
  - Once the pod exists, the Secret and ConfigMap get an ownerReference to it,
    so the garbage collector removes them with the pod even if this controller
    restarts before cleaning up.
  - When the pod create fails without an answer (a timeout), the pod is read
    back before anything is cleaned up: it may have been created.

  The monitor polls the pod every five seconds until it reaches a terminal
  phase and exits with that result:

  - `:normal` when the pod Succeeded
  - `{:pod_failed, reason}` when it Failed (the pod's reason, else the runner
    container's terminated reason and exit code)
  - `:pod_lost` when the pod is gone
  - `{:pod_monitor_unauthorized, reason}` when the API has answered 401/403 for
    longer than five minutes

  A Pending pod is never timed out here: Kueue may hold it behind its
  scheduling gate for as long as the queue is full. `activeDeadlineSeconds`
  still bounds a pod once it starts.

  That monitor is interim: it uses the controller's current `RunLauncher`
  behaviour, where the orchestrator monitors the returned pid. The process
  launcher's watcher step replaces it once both branches merge. `alive?/1` and
  `stop/1` already read the pod, so adoption and cancellation need no change.

  On a terminal phase the monitor deletes the run's Secret and ConfigMap. The
  pod is kept for its logs; a janitor is expected to remove old pods
  separately.

  `start/2` accepts either a `%SymphonyElixir.RunSpec{}` or the current
  behaviour's zero-arity function plus `spec: %RunSpec{}` in opts, so wiring can
  keep calling it the same way as the other launchers.
  """

  @behaviour SymphonyElixir.RunLauncher

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Kube
  alias SymphonyElixir.RunLauncher.Kubernetes.PodSpec
  alias SymphonyElixir.RunSpec
  alias SymphonyElixir.SymphonyConfig
  alias SymphonyElixir.Workflow

  # Follow-up (pod watch): replace the per-run poll with one pod watch (or
  # informer) over the runner label. At 5s per run, 1000 concurrent runs are
  # 200 GET/s against the API server; a watch is one stream. See
  # docs/durable-runs.md.
  @poll_interval_ms 5_000
  @unauthorized_timeout_ms 300_000
  @prefix "k8s:"

  @doc """
  Starts the run's Secret, ConfigMap, pod and monitor.

  Options: `:spec` (when called with a function), `:settings` (defaults to the
  loaded config), `:config_path` (the config file handed to the runner;
  defaults to the controller's own `symphony.yml` or `WORKFLOW.md`),
  `:poll_interval_ms`, `:unauthorized_timeout_ms`, and any
  `SymphonyElixir.Kube` options (`:base_url`, `:token`, `:service_account_dir`,
  `:req_options`).
  """
  @impl true
  @spec start((-> any()) | RunSpec.t(), keyword()) :: {:ok, pid(), String.t()} | {:error, term()}
  def start(fun, opts) when is_function(fun, 0) do
    case Keyword.fetch(opts, :spec) do
      {:ok, %RunSpec{} = spec} -> start(spec, Keyword.delete(opts, :spec))
      {:ok, other} -> {:error, {:invalid_run_spec, other}}
      :error -> {:error, :missing_run_spec}
    end
  end

  def start(%RunSpec{} = spec, opts) do
    with {:ok, settings} <- settings(opts),
         {:ok, runner_config} <- runner_config(opts),
         {:ok, rendered} <- PodSpec.render(spec, settings, runner_config),
         {:ok, client} <- Kube.client(opts) do
      create_and_watch(rendered, client, opts)
    end
  end

  @doc "Whether the pod named by a reference exists and is Pending or Running."
  @impl true
  @spec alive?(String.t()) :: boolean()
  def alive?(ref) when is_binary(ref) do
    with {:ok, namespace, name} <- parse_ref(ref),
         {:ok, client} <- Kube.client(),
         {:ok, pod} <- Kube.get_pod(client, namespace, name) do
      phase(pod) in ["Pending", "Running"]
    else
      _ -> false
    end
  end

  def alive?(_ref), do: false

  @doc "Deletes the pod, its Secret and its ConfigMap; missing objects are not an error."
  @impl true
  @spec stop(String.t()) :: :ok
  def stop(ref) when is_binary(ref) do
    with {:ok, namespace, name} <- parse_ref(ref),
         {:ok, client} <- Kube.client() do
      _ = Kube.delete_pod(client, namespace, name)
      _ = Kube.delete_secret(client, namespace, name)
      _ = Kube.delete_config_map(client, namespace, name)
    end

    :ok
  end

  def stop(_ref), do: :ok

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

  defp create_and_watch(rendered, client, opts) do
    with :ok <- create_replacing(client, rendered, :secret),
         :ok <- create_replacing(client, rendered, :config_map) do
      case create_pod(client, rendered) do
        {:ok, pod} ->
          own_run_objects(client, rendered, pod)
          {:ok, start_monitor(rendered, client, opts), rendered.ref}

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

  defp start_monitor(rendered, client, opts) do
    state = %{
      rendered: rendered,
      client: client,
      interval: Keyword.get(opts, :poll_interval_ms, @poll_interval_ms),
      unauthorized_timeout: Keyword.get(opts, :unauthorized_timeout_ms, @unauthorized_timeout_ms),
      unauthorized_since: nil
    }

    spawn(fn -> monitor(state) end)
  end

  defp monitor(state) do
    Process.sleep(state.interval)

    case Kube.get_pod(state.client, state.rendered.namespace, state.rendered.name) do
      {:ok, pod} -> monitor_phase(%{state | unauthorized_since: nil}, phase(pod), pod)
      {:error, :not_found} -> finish(state, :pod_lost)
      {:error, {:http_error, status, _body} = reason} when status in [401, 403] -> monitor_unauthorized(state, reason)
      {:error, reason} -> monitor_retry(state, reason)
    end
  end

  defp monitor_phase(state, "Succeeded", _pod), do: finish(state, :normal)
  defp monitor_phase(state, "Failed", pod), do: finish(state, {:pod_failed, failure_reason(pod)})
  defp monitor_phase(state, _phase, _pod), do: monitor(state)

  # A rotated token is picked up on the next request, so a short burst of
  # 401/403 is retried; one that persists means the controller lost access.
  defp monitor_unauthorized(state, reason) do
    now = System.monotonic_time(:millisecond)
    since = state.unauthorized_since || now

    if now - since >= state.unauthorized_timeout do
      Logger.error("Runner pod poll unauthorized for too long run=#{state.rendered.ref} reason=#{inspect(reason, limit: 5)}")
      exit({:pod_monitor_unauthorized, reason})
    else
      monitor_retry(%{state | unauthorized_since: since}, reason)
    end
  end

  defp monitor_retry(state, reason) do
    Logger.warning("Runner pod poll failed run=#{state.rendered.ref} reason=#{inspect(reason, limit: 5)}")

    monitor(state)
  end

  defp finish(state, reason) do
    cleanup_run_objects(state.rendered, state.client)
    exit(reason)
  end

  defp cleanup_run_objects(rendered, client) do
    for kind <- [:secret, :config_map] do
      case delete(client, rendered, kind) do
        {:ok, _response} -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> Logger.warning("Runner #{kind} cleanup failed run=#{rendered.ref} reason=#{inspect(reason, limit: 5)}")
      end
    end

    :ok
  end

  defp phase(%{"status" => %{"phase" => phase}}) when is_binary(phase), do: phase
  defp phase(_pod), do: nil

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
