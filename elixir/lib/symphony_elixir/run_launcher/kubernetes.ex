defmodule SymphonyElixir.RunLauncher.Kubernetes do
  @moduledoc """
  Starts each run as a runner pod on Kubernetes.

  `start/2` renders the run's Secret and pod (see
  `SymphonyElixir.RunLauncher.Kubernetes.PodSpec`), creates the Secret, then the
  pod, and returns a lightweight monitor process and the reference
  `"k8s:<namespace>/<pod>"`. The monitor polls the pod every five seconds until
  it reaches a terminal phase and exits with that result:

  - `:normal` when the pod Succeeded
  - `{:pod_failed, reason}` when it Failed
  - `:pod_lost` when the pod is gone

  That monitor is interim: it uses the controller's current `RunLauncher`
  behaviour, where the orchestrator monitors the returned pid. The process
  launcher's watcher step replaces it once both branches merge. `alive?/1` and
  `stop/1` already read the pod, so adoption and cancellation need no change.

  On a terminal phase the monitor deletes the run's Secret. The pod is kept for
  its logs; a janitor is expected to remove old pods separately.

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

  @poll_interval_ms 5_000
  @prefix "k8s:"

  @doc """
  Starts the run's Secret, pod and monitor.

  Options: `:spec` (when called with a function), `:settings` (defaults to the
  loaded config), `:poll_interval_ms`, and any `SymphonyElixir.Kube` options
  (`:base_url`, `:token`, `:service_account_dir`, `:req_options`).
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
         {:ok, rendered} <- PodSpec.render(spec, settings),
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

  @doc "Deletes the pod and its Secret; a missing pod or Secret is not an error."
  @impl true
  @spec stop(String.t()) :: :ok
  def stop(ref) when is_binary(ref) do
    with {:ok, namespace, name} <- parse_ref(ref),
         {:ok, client} <- Kube.client() do
      _ = Kube.delete_pod(client, namespace, name)
      _ = Kube.delete_secret(client, namespace, name)
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

  defp create_and_watch(rendered, client, opts) do
    with {:ok, _secret} <- Kube.create_secret(client, rendered.namespace, rendered.secret) do
      case Kube.create_pod(client, rendered.namespace, rendered.pod) do
        {:ok, _pod} ->
          {:ok, start_monitor(rendered, client, opts), rendered.ref}

        {:error, reason} ->
          cleanup_secret(rendered, client)
          {:error, reason}
      end
    end
  end

  defp start_monitor(rendered, client, opts) do
    interval = Keyword.get(opts, :poll_interval_ms, @poll_interval_ms)
    spawn(fn -> monitor(rendered, client, interval) end)
  end

  defp monitor(rendered, client, interval) do
    Process.sleep(interval)

    case Kube.get_pod(client, rendered.namespace, rendered.name) do
      {:ok, pod} -> monitor_phase(rendered, client, interval, phase(pod), pod)
      {:error, :not_found} -> finish(rendered, client, :pod_lost)
      {:error, reason} -> monitor_retry(rendered, client, interval, reason)
    end
  end

  defp monitor_phase(rendered, client, _interval, "Succeeded", _pod), do: finish(rendered, client, :normal)

  defp monitor_phase(rendered, client, _interval, "Failed", pod) do
    finish(rendered, client, {:pod_failed, failure_reason(pod)})
  end

  defp monitor_phase(rendered, client, interval, _phase, _pod), do: monitor(rendered, client, interval)

  defp monitor_retry(rendered, client, interval, reason) do
    Logger.warning("Runner pod poll failed run=#{rendered.ref} reason=#{inspect(reason, limit: 5)}")

    monitor(rendered, client, interval)
  end

  defp finish(rendered, client, reason) do
    cleanup_secret(rendered, client)
    exit(reason)
  end

  defp cleanup_secret(rendered, client) do
    case Kube.delete_secret(client, rendered.namespace, rendered.name) do
      {:ok, _response} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> Logger.warning("Runner Secret cleanup failed run=#{rendered.ref} reason=#{inspect(reason, limit: 5)}")
    end

    :ok
  end

  defp phase(%{"status" => %{"phase" => phase}}) when is_binary(phase), do: phase
  defp phase(_pod), do: nil

  defp failure_reason(%{"status" => %{"reason" => reason}}) when is_binary(reason) and reason != "", do: reason
  defp failure_reason(_pod), do: "failed"

  defp parse_ref(@prefix <> rest) do
    case String.split(rest, "/", parts: 2) do
      [namespace, name] when namespace != "" and name != "" -> {:ok, namespace, name}
      _ -> :error
    end
  end

  defp parse_ref(_ref), do: :error
end
