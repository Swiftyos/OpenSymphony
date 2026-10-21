defmodule SymphonyElixir.RunLauncher.Kubernetes.PodSpecTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunLauncher.Kubernetes.PodSpec
  alias SymphonyElixir.RunSpec

  setup do
    spec = %RunSpec{
      run_id: "Run ABC_1",
      epoch: 2,
      attempt: 1,
      issue: %Issue{id: "issue-1", identifier: "MT_42", title: "A title"},
      backend: "claude",
      controller_url: "http://symphony:4000",
      token: "run-token"
    }

    %{spec: spec}
  end

  test "the pod satisfies every admission rule the GKE policy checks", %{spec: spec} do
    settings = settings!(%{})

    assert {:ok, rendered} = PodSpec.render(spec, settings)
    assert rendered.namespace == "symphony-runs"
    assert rendered.name == "run-run-abc-1"
    assert rendered.ref == "k8s:symphony-runs/run-run-abc-1"

    pod = rendered.pod
    assert pod["metadata"]["name"] == rendered.name
    assert pod["metadata"]["namespace"] == "symphony-runs"
    assert pod["metadata"]["labels"]["symphony.n8n.io/run-id"] == "run-abc-1"
    assert pod["metadata"]["labels"]["symphony.n8n.io/issue"] == "mt_42"
    assert pod["metadata"]["labels"]["app.kubernetes.io/name"] == "symphony-runner"

    spec_doc = pod["spec"]
    assert spec_doc["runtimeClassName"] == "gvisor"
    assert spec_doc["serviceAccountName"] == "symphony-runner"
    assert spec_doc["automountServiceAccountToken"] == false
    assert spec_doc["nodeSelector"] == %{"research.n8n.io/pool" => "agents-sandbox"}

    assert [toleration] = spec_doc["tolerations"]
    assert toleration["key"] == "research.n8n.io/workload"
    assert toleration["value"] == "agents-sandbox"
    assert toleration["effect"] == "NoSchedule"

    assert spec_doc["restartPolicy"] == "Never"
    assert spec_doc["activeDeadlineSeconds"] == 21_600
    assert spec_doc["securityContext"]["runAsNonRoot"] == true
    assert spec_doc["securityContext"]["seccompProfile"] == %{"type" => "RuntimeDefault"}

    refute Enum.any?(spec_doc["volumes"], &Map.has_key?(&1, "hostPath"))

    for container <- spec_doc["containers"] ++ spec_doc["initContainers"] do
      assert container["securityContext"]["runAsNonRoot"] == true
      assert container["securityContext"]["allowPrivilegeEscalation"] == false
      assert container["securityContext"]["capabilities"] == %{"drop" => ["ALL"]}
      refute Map.has_key?(container["securityContext"]["capabilities"], "add")
      assert container["securityContext"]["seccompProfile"] == %{"type" => "RuntimeDefault"}
    end

    assert [init] = spec_doc["initContainers"]
    assert init["name"] == "agent-tools"
    assert init["image"] == "registry.test/symphony-agent-tools:test"
    assert init["args"] == ["/opt/symphony"]
    assert init["volumeMounts"] == [%{"name" => "agent-tools", "mountPath" => "/opt/symphony"}]

    assert [runner] = spec_doc["containers"]
    assert runner["name"] == "runner"
    assert runner["image"] == "registry.test/symphony:test"

    assert runner["args"] == [
             "runner",
             "/run/symphony/spec.json",
             "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
           ]

    assert %{"name" => "PATH", "value" => path} = hd(runner["env"])
    assert path =~ "/opt/symphony/bin"

    assert %{"name" => "ANTHROPIC_API_KEY", "valueFrom" => %{"secretKeyRef" => %{"name" => "symphony-anthropic", "key" => "api-key"}}} =
             Enum.at(runner["env"], 1)

    assert %{"name" => "GITHUB_TOKEN", "valueFrom" => %{"secretKeyRef" => %{"name" => "symphony-github", "key" => "token"}}} =
             Enum.at(runner["env"], 2)

    assert %{"name" => "agent-tools", "mountPath" => "/opt/symphony"} in runner["volumeMounts"]
    assert %{"name" => "run-spec", "mountPath" => "/run/symphony", "readOnly" => true} in runner["volumeMounts"]
    assert %{"name" => "workspace", "mountPath" => "/workspace"} in runner["volumeMounts"]

    assert runner["resources"] == %{
             "requests" => %{"cpu" => "500m", "memory" => "1Gi"},
             "limits" => %{"cpu" => "2", "memory" => "4Gi"}
           }

    assert [tools, secret, workspace] = spec_doc["volumes"]
    assert tools == %{"name" => "agent-tools", "emptyDir" => %{}}
    assert workspace == %{"name" => "workspace", "emptyDir" => %{}}
    assert secret["name"] == "run-spec"
    assert secret["secret"]["secretName"] == rendered.name
    assert secret["secret"]["defaultMode"] == 0o400

    assert [
             %{
               "key" => "spec.json",
               "path" => "spec.json",
               "mode" => 0o400
             }
           ] = secret["secret"]["items"]

    # The policy allows mounting only Secrets named run-<run-id label>.
    assert String.starts_with?(secret["secret"]["secretName"], "run-" <> pod["metadata"]["labels"]["symphony.n8n.io/run-id"])

    for volume <- spec_doc["volumes"] do
      refute Map.has_key?(volume, "projected")
    end
  end

  test "the Secret carries the run spec", %{spec: spec} do
    settings = settings!(%{})

    assert {:ok, rendered} = PodSpec.render(spec, settings)
    secret = rendered.secret

    assert secret["kind"] == "Secret"
    assert secret["type"] == "Opaque"
    assert secret["metadata"]["name"] == "run-run-abc-1"
    assert secret["metadata"]["namespace"] == "symphony-runs"
    assert secret["metadata"]["labels"]["symphony.n8n.io/run-id"] == "run-abc-1"

    document = Jason.decode!(secret["stringData"]["spec.json"])
    assert document["run_id"] == "Run ABC_1"
    assert document["epoch"] == 2
    assert document["token"] == "run-token"
    assert document["issue"]["identifier"] == "MT_42"
  end

  test "config overrides the images, resources, namespace, deadline and secret env", %{spec: spec} do
    settings =
      settings!(%{
        "namespace" => "Sandbox-Runs",
        "runner_image" => "registry.test/custom-runner:1",
        "agent_tools_image" => "registry.test/custom-tools:1",
        "cpu_request" => "1",
        "cpu_limit" => "4",
        "memory_request" => "2Gi",
        "memory_limit" => "8Gi",
        "active_deadline_seconds" => 60,
        "secret_env" => [%{"env" => "CUSTOM", "secret" => "custom-secret", "key" => "value"}]
      })

    assert {:ok, rendered} = PodSpec.render(spec, settings)
    assert rendered.namespace == "sandbox-runs"

    pod_spec = rendered.pod["spec"]
    assert pod_spec["activeDeadlineSeconds"] == 60
    assert [init] = pod_spec["initContainers"]
    assert init["image"] == "registry.test/custom-tools:1"
    assert [runner] = pod_spec["containers"]
    assert runner["image"] == "registry.test/custom-runner:1"

    assert runner["resources"] == %{
             "requests" => %{"cpu" => "1", "memory" => "2Gi"},
             "limits" => %{"cpu" => "4", "memory" => "8Gi"}
           }

    assert %{
             "name" => "CUSTOM",
             "valueFrom" => %{"secretKeyRef" => %{"name" => "custom-secret", "key" => "value"}}
           } = List.last(runner["env"])
  end

  test "a missing issue and an empty run id still render valid names and labels", %{spec: spec} do
    spec = %{spec | run_id: "", issue: nil}
    settings = settings!(%{})

    assert {:ok, rendered} = PodSpec.render(spec, settings)
    assert rendered.name == "run-run"
    assert rendered.pod["metadata"]["labels"]["symphony.n8n.io/run-id"] == "run"
    assert rendered.pod["metadata"]["labels"]["symphony.n8n.io/issue"] == "unknown"
  end

  test "a run without configured secret env still gets PATH", %{spec: spec} do
    settings = settings!(%{})
    kube = %{settings.agent.kubernetes | secret_env: nil}
    settings = %{settings | agent: %{settings.agent | kubernetes: kube}}

    assert {:ok, rendered} = PodSpec.render(spec, settings)
    assert [runner] = rendered.pod["spec"]["containers"]
    assert runner["env"] == []
  end

  test "the run id is lowercased, DNS safe and limited in length" do
    assert PodSpec.resource_name("AbC_123/xyz") == "run-abc-123-xyz"
    assert PodSpec.resource_name("---") == "run-run"
    assert PodSpec.resource_name(String.duplicate("a", 80)) == "run-" <> String.duplicate("a", 59)
    assert PodSpec.run_id_label("AbC_123/xyz") == "abc-123-xyz"
  end

  test "a blank issue identifier becomes the unknown label", %{spec: spec} do
    spec = %{spec | issue: %Issue{identifier: "  "}}

    assert {:ok, rendered} = PodSpec.render(spec, settings!(%{}))
    assert rendered.pod["metadata"]["labels"]["symphony.n8n.io/issue"] == "unknown"
  end

  test "missing images are rejected only when the launcher renders a pod", %{spec: spec} do
    assert {:error, {:invalid_kubernetes_config, "agent.kubernetes.runner_image is required"}} =
             PodSpec.render(spec, bare_settings!(%{}))

    assert {:error, {:invalid_kubernetes_config, "agent.kubernetes.agent_tools_image is required"}} =
             PodSpec.render(spec, bare_settings!(%{"runner_image" => "registry.test/symphony:test"}))

    assert {:error, {:invalid_kubernetes_config, "agent.kubernetes.runner_image is required"}} =
             PodSpec.render(spec, bare_settings!(%{"agent_tools_image" => "registry.test/tools:test"}))
  end

  defp bare_settings!(kubernetes) do
    assert {:ok, settings} =
             Schema.parse(%{
               "workspace" => %{"root" => "/workspace"},
               "agent" => %{"kubernetes" => kubernetes}
             })

    settings
  end

  defp settings!(kubernetes_overrides) do
    kubernetes =
      Map.merge(
        %{
          "runner_image" => "registry.test/symphony:test",
          "agent_tools_image" => "registry.test/symphony-agent-tools:test",
          "secret_env" => [
            %{"env" => "ANTHROPIC_API_KEY", "secret" => "symphony-anthropic", "key" => "api-key"},
            %{"env" => "GITHUB_TOKEN", "secret" => "symphony-github", "key" => "token"}
          ]
        },
        kubernetes_overrides
      )

    assert {:ok, settings} =
             Schema.parse(%{
               "workspace" => %{"root" => "/workspace"},
               "agent" => %{"kubernetes" => kubernetes}
             })

    settings
  end
end
