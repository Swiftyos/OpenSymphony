defmodule SymphonyElixir.RunLauncher.Kubernetes.PodSpec do
  @moduledoc """
  Renders a run's pod and its per-run Secret.

  The pod is the only shape the `symphony-runs` admission policy admits: gVisor,
  the `symphony-runner` service account without a token, the `agents-sandbox`
  pool selector and toleration, and non-root containers that drop every
  capability. The Secret carries `spec.json` and the ConfigMap the controller's
  config; both are named `run-<run-id>`, the prefix the policy requires of every
  mounted Secret and ConfigMap. The pod is labelled for its Kueue LocalQueue.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.RunSpec

  @run_label "symphony.n8n.io/run-id"
  @run_annotation "symphony.n8n.io/run-id"
  @issue_label "symphony.n8n.io/issue"
  @app_label "app.kubernetes.io/name"
  @queue_label "kueue.x-k8s.io/queue-name"
  @app_name "symphony-runner"
  @spec_volume "run-spec"
  @config_volume "run-config"
  @tools_volume "agent-tools"
  @workspace_volume "workspace"
  @spec_dir "/run/symphony"
  @config_dir "/etc/symphony"
  @tools_dir "/opt/symphony"
  @guardrail_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @max_run_id_length 59

  @typedoc """
  The controller config the runner boots with: the file name inside the
  ConfigMap (`symphony.yml` or `WORKFLOW.md`, which picks the runner's config
  mode) and its contents.
  """
  @type runner_config :: %{file_name: String.t(), content: String.t()}

  @doc """
  Renders `%{namespace, name, ref, secret, config_map, pod}` for a run.

  `settings` is the parsed `SymphonyElixir.Config.Schema`; only
  `agent.kubernetes` and `workspace.root` are used. The images and
  `agent.kubernetes.controller_url` (which the spec's `controller_url` and
  `git_mirror_url` are built from) are required. The workspace `emptyDir` is
  mounted at the spec's `workspace_root` when it has one, else at
  `workspace.root`. `runner_config` becomes the per-run ConfigMap the runner is
  started with. A missing image or controller URL is an error here, not in the
  general schema, so an install that doesn't use this launcher never has to
  configure one.
  """
  @spec render(RunSpec.t(), Schema.t(), runner_config()) :: {:ok, map()} | {:error, term()}
  def render(%RunSpec{} = spec, %Schema{} = settings, %{file_name: file_name, content: content}) do
    kube = settings.agent.kubernetes

    with :ok <- validate_config(kube) do
      name = resource_name(spec.run_id)
      namespace = kube.namespace
      labels = labels(spec, name, kube)
      metadata = metadata(spec, name, namespace, labels)
      workspace_root = Map.get(spec, :workspace_root) || settings.workspace.root

      {:ok,
       %{
         namespace: namespace,
         name: name,
         ref: "k8s:#{namespace}/#{name}",
         secret: secret(spec, metadata),
         config_map: config_map(metadata, file_name, content),
         pod: pod(kube, name, metadata, workspace_root, file_name)
       }}
    end
  end

  @doc """
  The pod, Secret and ConfigMap name for a run id: `run-` plus the run id
  hex-encoded, so case-sensitive ids (base64url) never collide after DNS
  lowercasing. An id too long (or empty) for a 63-character label uses `h` plus
  a SHA-256 prefix instead; `h` is not a hex digit, so the two never overlap.
  """
  @spec resource_name(String.t()) :: String.t()
  def resource_name(run_id), do: "run-" <> run_id_label(run_id)

  @doc "The `symphony.n8n.io/run-id` label: the name without its `run-` prefix."
  @spec run_id_label(String.t()) :: String.t()
  def run_id_label(run_id) do
    run_id = to_string(run_id)
    hex = Base.encode16(run_id, case: :lower)

    if hex != "" and byte_size(hex) <= @max_run_id_length do
      hex
    else
      "h" <> binary_part(Base.encode16(:crypto.hash(:sha256, run_id), case: :lower), 0, @max_run_id_length - 1)
    end
  end

  defp validate_config(kube) do
    cond do
      blank?(kube.runner_image) ->
        {:error, {:invalid_kubernetes_config, "agent.kubernetes.runner_image is required"}}

      blank?(kube.agent_tools_image) ->
        {:error, {:invalid_kubernetes_config, "agent.kubernetes.agent_tools_image is required"}}

      # A pod cannot reach the controller's loopback address.
      blank?(kube.controller_url) ->
        {:error, {:invalid_kubernetes_config, "agent.kubernetes.controller_url is required"}}

      true ->
        :ok
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp labels(spec, name, kube) do
    issue = spec.issue || %{}

    %{
      @run_label => String.replace_prefix(name, "run-", ""),
      @issue_label => label_value(Map.get(issue, :identifier) || Map.get(issue, "identifier")),
      @app_label => @app_name
    }
    |> put_queue_label(kube.queue_name)
  end

  # Kueue admits (and counts against the ClusterQueue) only pods labelled with
  # a LocalQueue; until then they stay Pending behind a scheduling gate.
  defp put_queue_label(labels, nil), do: labels
  defp put_queue_label(labels, queue_name), do: Map.put(labels, @queue_label, queue_name)

  defp metadata(spec, name, namespace, labels) do
    %{
      "name" => name,
      "namespace" => namespace,
      "labels" => labels,
      "annotations" => %{@run_annotation => to_string(spec.run_id)}
    }
  end

  defp label_value(nil), do: "unknown"

  defp label_value(value) do
    label =
      value
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_.-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 63)
      |> String.trim("-")

    if label == "", do: "unknown", else: label
  end

  defp secret(spec, metadata) do
    %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "metadata" => metadata,
      "type" => "Opaque",
      "stringData" => %{"spec.json" => Jason.encode!(RunSpec.to_map(spec))}
    }
  end

  defp config_map(metadata, file_name, content) do
    %{
      "apiVersion" => "v1",
      "kind" => "ConfigMap",
      "metadata" => metadata,
      "data" => %{file_name => content}
    }
  end

  defp pod(kube, name, metadata, workspace_root, config_file_name) do
    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => metadata,
      "spec" => %{
        "runtimeClassName" => "gvisor",
        "serviceAccountName" => "symphony-runner",
        "automountServiceAccountToken" => false,
        "nodeSelector" => %{"research.n8n.io/pool" => "agents-sandbox"},
        "tolerations" => [
          %{
            "key" => "research.n8n.io/workload",
            "operator" => "Equal",
            "value" => "agents-sandbox",
            "effect" => "NoSchedule"
          }
        ],
        "restartPolicy" => "Never",
        "activeDeadlineSeconds" => kube.active_deadline_seconds,
        # runAsNonRoot alone fails for an image whose USER is a name: the
        # kubelet cannot prove a name is non-root. The numeric ids also make
        # fsGroup own the Secret and emptyDir volumes, so 0440 is readable.
        "securityContext" => %{
          "runAsNonRoot" => true,
          "runAsUser" => kube.run_as_user,
          "runAsGroup" => kube.run_as_user,
          "fsGroup" => kube.run_as_user,
          "seccompProfile" => %{"type" => "RuntimeDefault"}
        },
        "initContainers" => [
          %{
            "name" => "agent-tools",
            "image" => kube.agent_tools_image,
            "args" => [@tools_dir],
            "securityContext" => container_security_context(),
            "volumeMounts" => [%{"name" => @tools_volume, "mountPath" => @tools_dir}],
            "resources" => init_resources(kube)
          }
        ],
        "containers" => [
          %{
            "name" => "runner",
            "image" => kube.runner_image,
            "args" => ["runner", @spec_dir <> "/spec.json", @config_dir <> "/" <> config_file_name, @guardrail_flag],
            "env" => env(kube.secret_env),
            "securityContext" => container_security_context(),
            "volumeMounts" => [
              %{"name" => @tools_volume, "mountPath" => @tools_dir},
              %{"name" => @spec_volume, "mountPath" => @spec_dir, "readOnly" => true},
              %{"name" => @config_volume, "mountPath" => @config_dir, "readOnly" => true},
              %{"name" => @workspace_volume, "mountPath" => workspace_root}
            ],
            "resources" => resources(kube)
          }
        ],
        "volumes" => [
          %{"name" => @tools_volume, "emptyDir" => empty_dir(kube.agent_tools_size_limit)},
          %{
            "name" => @spec_volume,
            "secret" => %{
              "secretName" => name,
              "defaultMode" => 0o440,
              "items" => [%{"key" => "spec.json", "path" => "spec.json", "mode" => 0o440}]
            }
          },
          %{
            "name" => @config_volume,
            "configMap" => %{
              "name" => name,
              "defaultMode" => 0o444,
              "items" => [%{"key" => config_file_name, "path" => config_file_name}]
            }
          },
          %{"name" => @workspace_volume, "emptyDir" => empty_dir(kube.workspace_size_limit)}
        ]
      }
    }
  end

  defp empty_dir(nil), do: %{}
  defp empty_dir(size_limit), do: %{"sizeLimit" => size_limit}

  defp resources(kube) do
    %{
      "requests" => put_present(%{"cpu" => kube.cpu_request, "memory" => kube.memory_request}, "ephemeral-storage", kube.ephemeral_storage_request),
      "limits" => put_present(%{"cpu" => kube.cpu_limit, "memory" => kube.memory_limit}, "ephemeral-storage", kube.ephemeral_storage_limit)
    }
  end

  # Explicit rather than left to the namespace LimitRange default.
  defp init_resources(kube) do
    case kube.agent_tools_ephemeral_storage_request do
      nil -> %{}
      request -> %{"requests" => %{"ephemeral-storage" => request}}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp container_security_context do
    %{
      "runAsNonRoot" => true,
      "allowPrivilegeEscalation" => false,
      "capabilities" => %{"drop" => ["ALL"]},
      "seccompProfile" => %{"type" => "RuntimeDefault"}
    }
  end

  # Follow-up: per-run GitHub App installation tokens belong in the run Secret once
  # the minter lands; add them here as secretKeyRef entries alongside secret_env.
  defp env(secret_env) when is_list(secret_env) do
    [
      %{
        "name" => "PATH",
        "value" => @tools_dir <> "/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      }
    ] ++
      Enum.map(secret_env, fn entry ->
        %{
          "name" => secret_env_value(entry, "env"),
          "valueFrom" => %{
            "secretKeyRef" => %{
              "name" => secret_env_value(entry, "secret"),
              "key" => secret_env_value(entry, "key")
            }
          }
        }
      end)
  end

  defp env(_secret_env), do: []

  defp secret_env_value(entry, field) do
    Map.get(entry, field) || Map.get(entry, String.to_atom(field))
  end
end
