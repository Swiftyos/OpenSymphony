defmodule SymphonyElixir.RunLauncher.Kubernetes.Janitor do
  @moduledoc """
  Removes what finished runner pods leave behind in the runner namespace.

  Every `agent.kubernetes.janitor_interval_ms` (five minutes), while the
  configured launcher is `SymphonyElixir.RunLauncher.Kubernetes`, it lists the
  `app.kubernetes.io/name=symphony-runner` pods and Secrets and:

    * deletes each pod that has Succeeded or Failed and finished longer than
      `agent.kubernetes.finished_pod_retention_ms` ago (one hour by default);
      the pod is kept until then for its logs. Garbage collection removes the
      Secret and ConfigMap it owns.
    * deletes each `run-*` Secret, and the ConfigMap of the same name, that has
      no pod and is older than ten minutes. A launch creates its Secret just
      before its pod, so a younger one may belong to a pod being created.

  Nothing else is touched: only objects with the runner label, in the
  configured namespace. A failed list or delete is logged and retried at the
  next sweep. Deletions are counted in
  `symphony_runner_janitor_deletions_total{kind="pod"|"secret"}`.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Capacity.Metrics
  alias SymphonyElixir.Config
  alias SymphonyElixir.Kube
  alias SymphonyElixir.RunLauncher
  alias SymphonyElixir.RunLauncher.Kubernetes

  @selector "app.kubernetes.io/name=symphony-runner"
  @orphan_grace_ms 600_000
  @default_interval_ms 300_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs one sweep now and returns what it deleted. Options: `:settings`
  (defaults to the loaded config), `:now` (a `DateTime`, for tests) and any
  `SymphonyElixir.Kube` client options.
  """
  @spec sweep(keyword()) :: {:ok, %{pods: [String.t()], secrets: [String.t()]}} | {:error, term()}
  def sweep(opts \\ []) do
    with {:ok, settings} <- settings(opts),
         {:ok, client} <- Kube.client(Keyword.drop(opts, [:settings, :now, :name, :interval_ms])),
         kube = settings.agent.kubernetes,
         {:ok, pods} <- Kube.list_pods(client, kube.namespace, @selector),
         {:ok, secrets} <- Kube.list_secrets(client, kube.namespace, @selector) do
      now_ms = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.to_unix(:millisecond)
      expired = for pod <- pods, expired_pod?(pod, now_ms, kube.finished_pod_retention_ms), do: name(pod)
      pod_names = MapSet.new(pods, &name/1)
      orphans = for secret <- secrets, orphan_secret?(secret, pod_names, now_ms), do: name(secret)

      deleted = %{
        pods: Enum.filter(expired, &deleted?(Kube.delete_pod(client, kube.namespace, &1), :pod, &1)),
        secrets: Enum.filter(orphans, &delete_orphan(client, kube.namespace, &1))
      }

      record_deletions("pod", deleted.pods)
      record_deletions("secret", deleted.secrets)
      {:ok, deleted}
    end
  end

  defp record_deletions(_kind, []), do: :ok
  defp record_deletions(kind, names), do: Metrics.record_counter("symphony_runner_janitor_deletions_total", [kind: kind], length(names))

  @impl true
  def init(opts) do
    state = %{opts: opts}
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    if RunLauncher.launcher() == Kubernetes do
      case sweep(state.opts) do
        {:ok, %{pods: [], secrets: []}} ->
          :ok

        {:ok, deleted} ->
          Logger.info("Runner janitor deleted pods=#{length(deleted.pods)} secrets=#{length(deleted.secrets)}")

        {:error, reason} ->
          Logger.warning("Runner janitor sweep failed reason=#{inspect(reason, limit: 5)}")
      end
    end

    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(state) do
    Process.send_after(self(), :sweep, interval_ms(state.opts))
  end

  defp interval_ms(opts) do
    Keyword.get_lazy(opts, :interval_ms, fn ->
      try do
        Config.settings!().agent.kubernetes.janitor_interval_ms
      rescue
        _error -> @default_interval_ms
      end
    end)
  end

  defp settings(opts) do
    case Keyword.fetch(opts, :settings) do
      {:ok, settings} -> {:ok, settings}
      :error -> Config.settings()
    end
  end

  defp expired_pod?(pod, now_ms, retention_ms) do
    Kubernetes.terminal?(pod) and
      case finished_at_ms(pod) do
        nil -> false
        finished_ms -> now_ms - finished_ms >= retention_ms
      end
  end

  # The latest container finish time; a terminal pod without one (evicted
  # before its containers ran) falls back to its start or creation time.
  defp finished_at_ms(pod) do
    status = Map.get(pod, "status", %{})

    finished =
      (List.wrap(status["containerStatuses"]) ++ List.wrap(status["initContainerStatuses"]))
      |> Enum.filter(&is_map/1)
      |> Enum.map(&timestamp_ms(get_in(&1, ["state", "terminated", "finishedAt"])))
      |> Enum.reject(&is_nil/1)

    case finished do
      [] -> timestamp_ms(status["startTime"]) || created_ms(pod)
      times -> Enum.max(times)
    end
  end

  defp orphan_secret?(secret, pod_names, now_ms) do
    secret_name = name(secret)

    is_binary(secret_name) and String.starts_with?(secret_name, "run-") and
      not MapSet.member?(pod_names, secret_name) and
      case created_ms(secret) do
        nil -> false
        created -> now_ms - created >= @orphan_grace_ms
      end
  end

  defp delete_orphan(client, namespace, secret_name) do
    deleted? = deleted?(Kube.delete_secret(client, namespace, secret_name), :secret, secret_name)
    _ = deleted?(Kube.delete_config_map(client, namespace, secret_name), :config_map, secret_name)
    deleted?
  end

  defp deleted?({:ok, _response}, _kind, _name), do: true
  defp deleted?({:error, :not_found}, _kind, _name), do: true

  defp deleted?({:error, reason}, kind, name) do
    Logger.warning("Runner janitor could not delete #{kind} name=#{name} reason=#{inspect(reason, limit: 5)}")
    false
  end

  defp name(object), do: get_in(object, ["metadata", "name"])

  defp created_ms(object), do: timestamp_ms(get_in(object, ["metadata", "creationTimestamp"]))

  defp timestamp_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      {:error, _reason} -> nil
    end
  end

  defp timestamp_ms(_value), do: nil
end
