defmodule SymphonyElixir.RunLauncher.Kubernetes.PodSpec do
  @moduledoc """
  Renders a run's pod and its per-run Secret.

  The pod is the only shape the `symphony-runs` admission policy admits: gVisor,
  the `symphony-runner` service account without a token, the `agents-sandbox`
  pool selector and toleration, and non-root containers that drop every
  capability. The Secret carries `spec.json` and is named `run-<run-id>`, the
  same prefix the policy requires of every mounted Secret.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.RunSpec

  @run_label "symphony.n8n.io/run-id"
  @issue_label "symphony.n8n.io/issue"
  @app_label "app.kubernetes.io/name"
  @app_name "symphony-runner"
  @spec_volume "run-spec"
  @tools_volume "agent-tools"
  @workspace_volume "workspace"
  @spec_dir "/run/symphony"
  @tools_dir "/opt/symphony"
  @guardrail_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @max_run_id_length 59

  @doc """
  Renders `%{namespace, name, ref, secret, pod}` for a run.

  `settings` is the parsed `SymphonyElixir.Config.Schema`; only
  `agent.kubernetes` and `workspace.root` are used. A missing image is an error
  here, not in the general schema, so an install that doesn't use this launcher
  never has to configure one.
  """
  @spec render(RunSpec.t(), Schema.t()) :: {:ok, map()} | {:error, term()}
  def render(%RunSpec{} = spec, %Schema{} = settings) do
    kube = settings.agent.kubernetes

    with :ok <- validate_images(kube) do
      name = resource_name(spec.run_id)
      namespace = kube.namespace
      labels = labels(spec, name)
      workspace_root = settings.workspace.root

      {:ok,
       %{
         namespace: namespace,
         name: name,
         ref: "k8s:#{namespace}/#{name}",
         secret: secret(spec, name, namespace, labels),
         pod: pod(kube, name, namespace, labels, workspace_root)
       }}
    end
  end

  @doc "The pod and Secret name for a run id, lowercased and DNS safe."
  @spec resource_name(String.t()) :: String.t()
  def resource_name(run_id) do
    suffix =
      run_id
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, @max_run_id_length)
      |> String.trim("-")

    "run-" <> if(suffix == "", do: "run", else: suffix)
  end

  @doc "The `symphony.n8n.io/run-id` label: the name without its `run-` prefix."
  @spec run_id_label(String.t()) :: String.t()
  def run_id_label(run_id) do
    run_id
    |> resource_name()
    |> String.replace_prefix("run-", "")
  end

  defp validate_images(kube) do
    cond do
      blank?(kube.runner_image) ->
        {:error, {:invalid_kubernetes_config, "agent.kubernetes.runner_image is required"}}

      blank?(kube.agent_tools_image) ->
        {:error, {:invalid_kubernetes_config, "agent.kubernetes.agent_tools_image is required"}}

      true ->
        :ok
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp labels(spec, name) do
    issue = spec.issue || %{}

    %{
      @run_label => String.replace_prefix(name, "run-", ""),
      @issue_label => label_value(Map.get(issue, :identifier) || Map.get(issue, "identifier")),
      @app_label => @app_name
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

  defp secret(spec, name, namespace, labels) do
    %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "metadata" => %{"name" => name, "namespace" => namespace, "labels" => labels},
      "type" => "Opaque",
      "stringData" => %{"spec.json" => Jason.encode!(RunSpec.to_map(spec))}
    }
  end

  defp pod(kube, name, namespace, labels, workspace_root) do
    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{"name" => name, "namespace" => namespace, "labels" => labels},
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
        "securityContext" => %{
          "runAsNonRoot" => true,
          "seccompProfile" => %{"type" => "RuntimeDefault"}
        },
        "initContainers" => [
          %{
            "name" => "agent-tools",
            "image" => kube.agent_tools_image,
            "args" => [@tools_dir],
            "securityContext" => container_security_context(),
            "volumeMounts" => [%{"name" => @tools_volume, "mountPath" => @tools_dir}]
          }
        ],
        "containers" => [
          %{
            "name" => "runner",
            "image" => kube.runner_image,
            "args" => ["runner", @spec_dir <> "/spec.json", @guardrail_flag],
            "env" => env(kube.secret_env),
            "securityContext" => container_security_context(),
            "volumeMounts" => [
              %{"name" => @tools_volume, "mountPath" => @tools_dir},
              %{"name" => @spec_volume, "mountPath" => @spec_dir, "readOnly" => true},
              %{"name" => @workspace_volume, "mountPath" => workspace_root}
            ],
            "resources" => %{
              "requests" => %{"cpu" => kube.cpu_request, "memory" => kube.memory_request},
              "limits" => %{"cpu" => kube.cpu_limit, "memory" => kube.memory_limit}
            }
          }
        ],
        "volumes" => [
          %{"name" => @tools_volume, "emptyDir" => %{}},
          %{
            "name" => @spec_volume,
            "secret" => %{
              "secretName" => name,
              "defaultMode" => 0o400,
              "items" => [%{"key" => "spec.json", "path" => "spec.json", "mode" => 0o400}]
            }
          },
          %{"name" => @workspace_volume, "emptyDir" => %{}}
        ]
      }
    }
  end

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
