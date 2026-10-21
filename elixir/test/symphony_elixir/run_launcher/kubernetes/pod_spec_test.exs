defmodule SymphonyElixir.RunLauncher.Kubernetes.PodSpecTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunLauncher.Kubernetes.PodSpec
  alias SymphonyElixir.RunSpec

  @runner_config %{file_name: "symphony.yml", content: "workspace:\n  root: /workspace\n"}
  # Base.encode16("Run ABC_1", case: :lower)
  @hex "52756e204142435f31"
  @name "run-" <> @hex

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
    assert {:ok, rendered} = PodSpec.render(spec, settings!(%{}), @runner_config)
    assert rendered.namespace == "symphony-runs"
    assert rendered.name == @name
    assert rendered.ref == "k8s:symphony-runs/" <> @name

    pod = rendered.pod
    assert pod["metadata"]["name"] == rendered.name
    assert pod["metadata"]["namespace"] == "symphony-runs"
    assert pod["metadata"]["labels"]["symphony.n8n.io/run-id"] == @hex
    assert pod["metadata"]["labels"]["symphony.n8n.io/issue"] == "mt_42"
    assert pod["metadata"]["labels"]["app.kubernetes.io/name"] == "symphony-runner"
    assert pod["metadata"]["labels"]["kueue.x-k8s.io/queue-name"] == "symphony"
    assert pod["metadata"]["annotations"]["symphony.n8n.io/run-id"] == "Run ABC_1"

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

    assert spec_doc["securityContext"] == %{
             "runAsNonRoot" => true,
             "runAsUser" => 10_001,
             "runAsGroup" => 10_001,
             "fsGroup" => 10_001,
             "seccompProfile" => %{"type" => "RuntimeDefault"}
           }

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
    assert init["resources"] == %{"requests" => %{"ephemeral-storage" => "256Mi"}}

    assert [runner] = spec_doc["containers"]
    assert runner["name"] == "runner"
    assert runner["image"] == "registry.test/symphony:test"

    assert runner["args"] == [
             "runner",
             "/run/symphony/spec.json",
             "/etc/symphony/symphony.yml",
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
    assert %{"name" => "run-config", "mountPath" => "/etc/symphony", "readOnly" => true} in runner["volumeMounts"]
    assert %{"name" => "workspace", "mountPath" => "/workspace"} in runner["volumeMounts"]

    assert runner["resources"] == %{
             "requests" => %{"cpu" => "500m", "memory" => "1Gi", "ephemeral-storage" => "2Gi"},
             "limits" => %{"cpu" => "2", "memory" => "4Gi", "ephemeral-storage" => "24Gi"}
           }

    assert [tools, secret, config, workspace] = spec_doc["volumes"]
    assert tools == %{"name" => "agent-tools", "emptyDir" => %{"sizeLimit" => "1Gi"}}
    assert workspace == %{"name" => "workspace", "emptyDir" => %{"sizeLimit" => "20Gi"}}
    assert secret["name"] == "run-spec"
    assert secret["secret"]["secretName"] == rendered.name
    # fsGroup owns the projected file, so group-read is what uid 10001 needs.
    assert secret["secret"]["defaultMode"] == 0o440
    assert [%{"key" => "spec.json", "path" => "spec.json", "mode" => 0o440}] = secret["secret"]["items"]

    assert config["name"] == "run-config"
    assert config["configMap"]["name"] == rendered.name
    assert config["configMap"]["defaultMode"] == 0o444
    assert config["configMap"]["items"] == [%{"key" => "symphony.yml", "path" => "symphony.yml"}]

    # The policy allows mounting only Secrets and ConfigMaps named run-<run-id label>.
    run_prefix = "run-" <> pod["metadata"]["labels"]["symphony.n8n.io/run-id"]
    assert String.starts_with?(secret["secret"]["secretName"], run_prefix)
    assert String.starts_with?(config["configMap"]["name"], run_prefix)

    for volume <- spec_doc["volumes"] do
      refute Map.has_key?(volume, "projected")
    end
  end

  test "the Secret carries the run spec and the ConfigMap the runner config", %{spec: spec} do
    assert {:ok, rendered} = PodSpec.render(spec, settings!(%{}), @runner_config)
    secret = rendered.secret

    assert secret["kind"] == "Secret"
    assert secret["type"] == "Opaque"
    assert secret["metadata"]["name"] == @name
    assert secret["metadata"]["namespace"] == "symphony-runs"
    assert secret["metadata"]["labels"]["symphony.n8n.io/run-id"] == @hex
    assert secret["metadata"]["annotations"]["symphony.n8n.io/run-id"] == "Run ABC_1"

    document = Jason.decode!(secret["stringData"]["spec.json"])
    assert document["run_id"] == "Run ABC_1"
    assert document["epoch"] == 2
    assert document["token"] == "run-token"
    assert document["issue"]["identifier"] == "MT_42"

    config_map = rendered.config_map
    assert config_map["kind"] == "ConfigMap"
    assert config_map["metadata"] == secret["metadata"]
    assert config_map["data"] == %{"symphony.yml" => @runner_config.content}
  end

  test "a WORKFLOW.md runner config is mounted under its own name", %{spec: spec} do
    config = %{file_name: "WORKFLOW.md", content: "---\n---\nPrompt"}

    assert {:ok, rendered} = PodSpec.render(spec, settings!(%{}), config)
    assert [runner] = rendered.pod["spec"]["containers"]
    assert Enum.at(runner["args"], 2) == "/etc/symphony/WORKFLOW.md"
    assert rendered.config_map["data"] == %{"WORKFLOW.md" => "---\n---\nPrompt"}
  end

  test "the workspace is mounted at the spec's workspace_root when it has one", %{spec: spec} do
    spec = Map.put(spec, :workspace_root, "/runs/workspace")

    assert {:ok, rendered} = PodSpec.render(spec, settings!(%{}), @runner_config)
    assert [runner] = rendered.pod["spec"]["containers"]
    assert %{"name" => "workspace", "mountPath" => "/runs/workspace"} in runner["volumeMounts"]
  end

  test "config overrides the images, resources, namespace, deadline, uid, queue and secret env", %{spec: spec} do
    settings =
      settings!(%{
        "namespace" => "Sandbox-Runs",
        "runner_image" => "registry.test/custom-runner:1",
        "agent_tools_image" => "registry.test/custom-tools:1",
        "cpu_request" => "1",
        "cpu_limit" => "4",
        "memory_request" => "2Gi",
        "memory_limit" => "8Gi",
        "ephemeral_storage_request" => "5Gi",
        "ephemeral_storage_limit" => "50Gi",
        "workspace_size_limit" => "40Gi",
        "agent_tools_size_limit" => "2Gi",
        "agent_tools_ephemeral_storage_request" => "512Mi",
        "active_deadline_seconds" => 60,
        "run_as_user" => 20_000,
        "queue_name" => "sandbox",
        "secret_env" => [%{"env" => "CUSTOM", "secret" => "custom-secret", "key" => "value"}]
      })

    assert {:ok, rendered} = PodSpec.render(spec, settings, @runner_config)
    assert rendered.namespace == "sandbox-runs"
    assert rendered.pod["metadata"]["labels"]["kueue.x-k8s.io/queue-name"] == "sandbox"

    pod_spec = rendered.pod["spec"]
    assert pod_spec["activeDeadlineSeconds"] == 60
    assert pod_spec["securityContext"]["runAsUser"] == 20_000
    assert pod_spec["securityContext"]["runAsGroup"] == 20_000
    assert pod_spec["securityContext"]["fsGroup"] == 20_000
    assert [init] = pod_spec["initContainers"]
    assert init["image"] == "registry.test/custom-tools:1"
    assert init["resources"] == %{"requests" => %{"ephemeral-storage" => "512Mi"}}
    assert [runner] = pod_spec["containers"]
    assert runner["image"] == "registry.test/custom-runner:1"

    assert runner["resources"] == %{
             "requests" => %{"cpu" => "1", "memory" => "2Gi", "ephemeral-storage" => "5Gi"},
             "limits" => %{"cpu" => "4", "memory" => "8Gi", "ephemeral-storage" => "50Gi"}
           }

    assert [tools, _secret, _config, workspace] = pod_spec["volumes"]
    assert tools["emptyDir"] == %{"sizeLimit" => "2Gi"}
    assert workspace["emptyDir"] == %{"sizeLimit" => "40Gi"}

    assert %{
             "name" => "CUSTOM",
             "valueFrom" => %{"secretKeyRef" => %{"name" => "custom-secret", "key" => "value"}}
           } = List.last(runner["env"])
  end

  test "blank queue, size limits and ephemeral storage are left off the pod", %{spec: spec} do
    settings =
      settings!(%{
        "queue_name" => "",
        "workspace_size_limit" => "",
        "agent_tools_size_limit" => " ",
        "ephemeral_storage_request" => "",
        "ephemeral_storage_limit" => "",
        "agent_tools_ephemeral_storage_request" => ""
      })

    assert {:ok, rendered} = PodSpec.render(spec, settings, @runner_config)
    refute Map.has_key?(rendered.pod["metadata"]["labels"], "kueue.x-k8s.io/queue-name")

    pod_spec = rendered.pod["spec"]
    assert [tools, _secret, _config, workspace] = pod_spec["volumes"]
    assert tools["emptyDir"] == %{}
    assert workspace["emptyDir"] == %{}
    assert [%{"resources" => %{}}] = pod_spec["initContainers"]

    assert [runner] = pod_spec["containers"]

    assert runner["resources"] == %{
             "requests" => %{"cpu" => "500m", "memory" => "1Gi"},
             "limits" => %{"cpu" => "2", "memory" => "4Gi"}
           }
  end

  test "the pod references only its own run-<id> Secret and ConfigMap, plus secret_env's shared Secrets", %{spec: spec} do
    assert {:ok, rendered} = PodSpec.render(spec, settings!(%{}), @runner_config)
    pod_spec = rendered.pod["spec"]

    volume_refs =
      for volume <- pod_spec["volumes"], ref = volume["secret"]["secretName"] || volume["configMap"]["name"], do: ref

    assert volume_refs == [rendered.name, rendered.name]

    key_refs =
      for container <- pod_spec["containers"] ++ pod_spec["initContainers"],
          env <- container["env"] || [],
          ref = get_in(env, ["valueFrom", "secretKeyRef", "name"]),
          do: ref

    assert key_refs == ["symphony-anthropic", "symphony-github"]
    refute Enum.any?(pod_spec["containers"] ++ pod_spec["initContainers"], &Map.has_key?(&1, "envFrom"))
  end

  test "a missing issue and an empty run id still render valid names and labels", %{spec: spec} do
    spec = %{spec | run_id: "", issue: nil}

    assert {:ok, rendered} = PodSpec.render(spec, settings!(%{}), @runner_config)
    assert "run-h" <> digest = rendered.name
    assert byte_size(digest) == 58
    assert rendered.pod["metadata"]["labels"]["symphony.n8n.io/run-id"] == "h" <> digest
    assert rendered.pod["metadata"]["labels"]["symphony.n8n.io/issue"] == "unknown"
    assert rendered.pod["metadata"]["annotations"]["symphony.n8n.io/run-id"] == ""
  end

  test "a run without configured secret env still gets PATH", %{spec: spec} do
    settings = settings!(%{})
    kube = %{settings.agent.kubernetes | secret_env: nil}
    settings = %{settings | agent: %{settings.agent | kubernetes: kube}}

    assert {:ok, rendered} = PodSpec.render(spec, settings, @runner_config)
    assert [runner] = rendered.pod["spec"]["containers"]
    assert runner["env"] == []
  end

  test "the run id is hex-encoded, so case-distinct ids never collide" do
    assert PodSpec.resource_name("AbC_1") == "run-" <> Base.encode16("AbC_1", case: :lower)
    assert PodSpec.resource_name("abc_1") != PodSpec.resource_name("AbC_1")
    assert PodSpec.run_id_label("AbC_1") == Base.encode16("AbC_1", case: :lower)

    # A real run id: 12 random bytes, base64url.
    run_id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    label = PodSpec.run_id_label(run_id)
    assert label =~ ~r/^[0-9a-f]{32}$/
    assert Base.decode16!(label, case: :lower) == run_id

    # Too long for a 63-character label: a stable digest that is never hex.
    long = String.duplicate("a", 30)
    assert "h" <> digest = PodSpec.run_id_label(long)
    assert byte_size(digest) == 58
    assert PodSpec.run_id_label(long) == "h" <> digest
    assert byte_size(PodSpec.resource_name(long)) == 63
    assert PodSpec.run_id_label(String.duplicate("a", 29)) == Base.encode16(String.duplicate("a", 29), case: :lower)
  end

  test "a blank issue identifier becomes the unknown label", %{spec: spec} do
    spec = %{spec | issue: %Issue{identifier: "  "}}

    assert {:ok, rendered} = PodSpec.render(spec, settings!(%{}), @runner_config)
    assert rendered.pod["metadata"]["labels"]["symphony.n8n.io/issue"] == "unknown"
  end

  test "missing images are rejected only when the launcher renders a pod", %{spec: spec} do
    assert {:error, {:invalid_kubernetes_config, "agent.kubernetes.runner_image is required"}} =
             PodSpec.render(spec, bare_settings!(%{}), @runner_config)

    assert {:error, {:invalid_kubernetes_config, "agent.kubernetes.agent_tools_image is required"}} =
             PodSpec.render(spec, bare_settings!(%{"runner_image" => "registry.test/symphony:test"}), @runner_config)

    assert {:error, {:invalid_kubernetes_config, "agent.kubernetes.runner_image is required"}} =
             PodSpec.render(spec, bare_settings!(%{"agent_tools_image" => "registry.test/tools:test"}), @runner_config)

    assert {:error, {:invalid_kubernetes_config, "agent.kubernetes.controller_url is required"}} =
             PodSpec.render(
               spec,
               bare_settings!(%{"runner_image" => "registry.test/symphony:test", "agent_tools_image" => "registry.test/tools:test"}),
               @runner_config
             )
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
          "controller_url" => "http://symphony.symphony.svc:4000",
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
