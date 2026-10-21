defmodule SymphonyElixir.ConfigCoverageSchemaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  defp parse!(config) do
    assert {:ok, settings} = Schema.parse(config)
    settings
  end

  defp parse_error(config) do
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(config)
    message
  end

  defp unset_env_name do
    name = "SYMPHONY_COVERAGE_UNSET_#{System.unique_integer([:positive])}"
    System.delete_env(name)
    name
  end

  describe "turn sandbox policy resolution" do
    test "resolve_turn_sandbox_policy returns an explicit policy unchanged" do
      settings = parse!(%{"codex" => %{"turn_sandbox_policy" => %{"type" => "readOnly"}}})

      assert Schema.resolve_turn_sandbox_policy(settings) == %{"type" => "readOnly"}
      assert Schema.resolve_turn_sandbox_policy(settings, "/tmp/ignored") == %{"type" => "readOnly"}
    end

    test "resolve_turn_sandbox_policy builds a workspace-write policy from the workspace" do
      settings = parse!(%{})

      default_policy = Schema.resolve_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [Path.expand(settings.workspace.root)]
      assert default_policy["networkAccess"] == false

      assert %{"writableRoots" => ["/tmp/custom-workspace"]} =
               Schema.resolve_turn_sandbox_policy(settings, "/tmp/custom-workspace")
    end

    test "resolve_turn_sandbox_policy falls back to the temp workspace root when no root is set" do
      settings = parse!(%{})
      settings = %{settings | workspace: %{settings.workspace | root: ""}}

      expected_root = Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))

      assert %{"writableRoots" => [^expected_root]} = Schema.resolve_turn_sandbox_policy(settings)
      assert %{"writableRoots" => [^expected_root]} = Schema.resolve_turn_sandbox_policy(settings, "")
    end

    test "resolve_runtime_turn_sandbox_policy uses the default arguments and explicit policies" do
      root = Path.join(System.tmp_dir!(), "symphony-coverage-runtime-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      settings = parse!(%{"workspace" => %{"root" => root}})
      {:ok, canonical_root} = SymphonyElixir.PathSafety.canonicalize(root)

      assert {:ok, %{"writableRoots" => [^canonical_root]}} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert {:ok, %{"writableRoots" => [^canonical_root]}} = Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      explicit = parse!(%{"codex" => %{"turn_sandbox_policy" => %{"type" => "dangerFullAccess"}}})
      assert {:ok, %{"type" => "dangerFullAccess"}} = Schema.resolve_runtime_turn_sandbox_policy(explicit)
    end

    test "resolve_runtime_turn_sandbox_policy rejects non-string workspace roots" do
      settings = parse!(%{})

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    end
  end

  describe "environment catalog validation" do
    test "parses and normalizes the catalog and team defaults" do
      settings =
        parse!(%{
          "environments" => %{
            "Python" => %{
              "image" => "registry.example.com/python:1",
              "resources" => %{"cpu" => 2, "memory" => "4g"},
              "allowed_images" => ["registry.example.com/"],
              "services" => [%{"name" => "db", "image" => "registry.example.com/postgres:16"}],
              "egress_extra" => ["api.example.com"],
              "max_services" => 2,
              "service_resources" => %{"cpu" => 1, "memory" => "512m"}
            }
          },
          "teams" => %{"pay" => %{"environment" => "python"}}
        })

      assert %{"python" => %{"image" => "registry.example.com/python:1"}} = settings.environments
      assert settings.teams == %{"PAY" => %{"environment" => "python"}}
      assert parse!(%{"teams" => %{"PAY" => %{}}}).teams == %{"PAY" => %{}}
    end

    test "rejects malformed catalog entries and team defaults" do
      for {config, message} <- [
            {%{"environments" => %{"x" => %{"image" => ""}}}, "needs an image"},
            {%{"environments" => %{"x" => "nope"}}, "must be a map"},
            {%{"environments" => %{"x" => %{"image" => "i", "resources" => "bad"}}}, "resources must be a map"},
            {%{"environments" => %{"x" => %{"image" => "i", "services" => "bad"}}}, "services must be a list"},
            {%{"environments" => %{"x" => %{"image" => "i", "allowed_images" => "bad"}}}, "allowed_images"},
            {%{"environments" => %{"x" => %{"image" => "i", "egress_extra" => "bad"}}}, "egress_extra"},
            {%{"environments" => %{"x" => %{"image" => "i", "allowed_images" => ["registry.example.com"]}}}, "must end in /, : or @"},
            {%{"environments" => %{"x" => %{"image" => "i", "max_services" => -1}}}, "max_services must be a non-negative integer"},
            {%{"environments" => %{"x" => %{"image" => "i", "max_services" => "2"}}}, "max_services must be a non-negative integer"},
            {%{"environments" => %{"x" => %{"image" => "i", "service_resources" => "bad"}}}, "service_resources must be a map"},
            {%{"environments" => "bad"}, "environments is invalid"},
            {%{"environments" => %{"" => %{"image" => "i"}}}, "environment names must be non-empty strings"},
            {%{"teams" => %{"PAY" => %{"environment" => "Bad/Name"}}}, "environment must be a catalog environment name"},
            {%{"teams" => %{"PAY" => "nope"}}, "must be a map"},
            {%{"teams" => "bad"}, "teams is invalid"},
            {%{"teams" => %{"PAY" => %{"environment" => 1}}}, "environment must be a catalog environment name"}
          ] do
        assert parse_error(config) =~ message
      end
    end
  end

  describe "pricing validation" do
    test "accepts non-negative per-mtok rates" do
      pricing = %{"claude" => %{"input_per_mtok" => 3.0, "output_per_mtok" => 15}}
      assert parse!(%{"pricing" => pricing}).pricing == pricing
    end

    test "rejects negative or unknown rate keys" do
      message = parse_error(%{"pricing" => %{"claude" => %{"input_per_mtok" => -1}}})
      assert message =~ "claude must set non-negative input_per_mtok / output_per_mtok / cached_input_per_mtok numbers, or openrouter_model"

      message = parse_error(%{"pricing" => %{"codex" => %{"bogus_rate" => 1}}})
      assert message =~ "codex must set non-negative"
    end

    test "rejects non-map pricing entries" do
      message = parse_error(%{"pricing" => %{"claude" => 5}})
      assert message =~ "claude must be a map of input_per_mtok / output_per_mtok"
    end
  end

  describe "kubernetes launcher config" do
    test "defaults, normalization and secret_env entries are carried through" do
      settings =
        parse!(%{
          "agent" => %{
            "kubernetes" => %{
              "namespace" => " Sandbox-Runs ",
              "runner_image" => " registry.test/symphony:test ",
              "agent_tools_image" => "registry.test/tools:test",
              "cpu_request" => "1",
              "cpu_limit" => "4",
              "memory_request" => "2Gi",
              "memory_limit" => "8Gi",
              "active_deadline_seconds" => 60,
              "run_as_user" => 20_000,
              "queue_name" => " sandbox ",
              "workspace_size_limit" => "40Gi",
              "agent_tools_size_limit" => "",
              "ephemeral_storage_request" => "5Gi",
              "ephemeral_storage_limit" => "50Gi",
              "secret_env" => [%{"env" => "ANTHROPIC_API_KEY", "secret" => "symphony-anthropic", "key" => "api-key"}]
            }
          }
        })

      kube = settings.agent.kubernetes
      assert kube.namespace == "sandbox-runs"
      assert kube.runner_image == "registry.test/symphony:test"
      assert kube.agent_tools_image == "registry.test/tools:test"
      assert kube.cpu_request == "1"
      assert kube.cpu_limit == "4"
      assert kube.memory_request == "2Gi"
      assert kube.memory_limit == "8Gi"
      assert kube.active_deadline_seconds == 60
      assert kube.run_as_user == 20_000
      assert kube.queue_name == "sandbox"
      assert kube.workspace_size_limit == "40Gi"
      assert kube.agent_tools_size_limit == nil
      assert kube.ephemeral_storage_request == "5Gi"
      assert kube.ephemeral_storage_limit == "50Gi"

      assert kube.secret_env == [
               %{"env" => "ANTHROPIC_API_KEY", "secret" => "symphony-anthropic", "key" => "api-key"}
             ]

      defaults = parse!(%{}).agent.kubernetes
      assert defaults.namespace == "symphony-runs"
      assert defaults.runner_image == nil
      assert defaults.agent_tools_image == nil
      assert defaults.cpu_request == "500m"
      assert defaults.cpu_limit == "2"
      assert defaults.memory_request == "1Gi"
      assert defaults.memory_limit == "4Gi"
      assert defaults.active_deadline_seconds == 21_600
      assert defaults.run_as_user == 10_001
      assert defaults.queue_name == "symphony"
      assert defaults.workspace_size_limit == "20Gi"
      assert defaults.agent_tools_size_limit == "1Gi"
      assert defaults.ephemeral_storage_request == "2Gi"
      assert defaults.ephemeral_storage_limit == "24Gi"
      assert defaults.secret_env == []
    end

    test "secret_env entries also accept atom keys" do
      changeset =
        Schema.Kubernetes.changeset(%Schema.Kubernetes{}, %{
          "secret_env" => [%{env: "TOKEN", secret: "a-secret", key: "token"}]
        })

      assert changeset.valid?
      assert changeset.changes.secret_env == [%{env: "TOKEN", secret: "a-secret", key: "token"}]
    end

    test "rejects an invalid namespace, deadline and secret_env entry" do
      assert parse_error(%{"agent" => %{"kubernetes" => %{"namespace" => "Bad_Name"}}}) =~
               "agent.kubernetes.namespace must be a DNS label"

      assert parse_error(%{"agent" => %{"kubernetes" => %{"namespace" => "  "}}}) =~
               "agent.kubernetes.namespace can't be blank"

      assert parse_error(%{"agent" => %{"kubernetes" => %{"active_deadline_seconds" => 0}}}) =~
               "agent.kubernetes.active_deadline_seconds must be greater than 0"

      assert parse_error(%{"agent" => %{"kubernetes" => %{"run_as_user" => 0}}}) =~
               "agent.kubernetes.run_as_user must be greater than 0"

      assert parse_error(%{"agent" => %{"kubernetes" => %{"queue_name" => "bad queue"}}}) =~
               "agent.kubernetes.queue_name must be a label value"

      assert parse_error(%{
               "agent" => %{"kubernetes" => %{"secret_env" => [%{"env" => "TOKEN", "secret" => "a-secret"}]}}
             }) =~ "agent.kubernetes.secret_env entries must set non-empty env, secret and key"

      assert parse_error(%{"agent" => %{"kubernetes" => %{"secret_env" => ["not-a-map"]}}}) =~
               "agent.kubernetes.secret_env"

      assert parse_error(%{"agent" => %{"kubernetes" => %{"memory_limit" => ""}}}) =~
               "agent.kubernetes.memory_limit can't be blank"
    end
  end

  describe "string normalizers" do
    test "normalize_optional_string trims, blanks to nil, and passes through non-strings" do
      assert Schema.normalize_optional_string(nil) == nil
      assert Schema.normalize_optional_string("   ") == nil
      assert Schema.normalize_optional_string("  value  ") == "value"
      assert Schema.normalize_optional_string(5) == 5
    end

    test "normalize_optional_effort trims, downcases, blanks to nil, and passes through non-strings" do
      assert Schema.normalize_optional_effort(nil) == nil
      assert Schema.normalize_optional_effort("  ") == nil
      assert Schema.normalize_optional_effort(" HIGH ") == "high"
      assert Schema.normalize_optional_effort(3) == 3
    end
  end

  describe "telemetry resource attributes" do
    test "drops blank resource attribute values" do
      settings =
        parse!(%{
          "telemetry" => %{"resource_attributes" => %{"team" => " core ", "blank" => "   ", "count" => 2}}
        })

      assert settings.telemetry.resource_attributes == %{"team" => "core", "count" => "2"}
    end
  end

  describe "tracker projects normalization" do
    test "top-level projects replace a non-map tracker section" do
      settings = parse!(%{"tracker" => "not-a-map", "projects" => [%{"slug" => "alpha"}]})

      assert [%Schema.TrackerProject{slug: "alpha"}] = settings.tracker.projects
    end

    test "non-map project entries are rejected" do
      assert parse_error(%{"tracker" => %{"projects" => ["just-a-string"]}}) =~ "tracker.projects"
    end

    test "projects without a slug or linear_project alias are not accepted" do
      assert parse_error(%{"tracker" => %{"projects" => [%{"slug" => "ok"}, %{"repo" => "owner/repo"}]}}) =~
               "tracker.projects[1].slug can't be blank"

      changeset = Schema.TrackerProject.changeset(%Schema.TrackerProject{}, %{"repo" => "owner/repo"})
      refute changeset.valid?
      assert {"can't be blank", _} = changeset.errors[:slug]
    end

    test "projects reject unknown backends" do
      assert parse_error(%{"tracker" => %{"projects" => [%{"slug" => "alpha", "backend" => "gpt"}]}}) =~
               "tracker.projects[0].backend must be one of"

      changeset = Schema.TrackerProject.changeset(%Schema.TrackerProject{}, %{"slug" => "alpha", "backend" => "gpt"})
      refute changeset.valid?
      assert {"must be one of: codex, opencode, claude", _} = changeset.errors[:backend]

      valid = Schema.TrackerProject.changeset(%Schema.TrackerProject{}, %{"slug" => "alpha", "backend" => "claude"})
      assert valid.valid?
    end

    test "unset env references resolve to nil for repo and workflow" do
      env_name = unset_env_name()

      settings =
        parse!(%{
          "tracker" => %{
            "projects" => [%{"slug" => "alpha", "repo" => "$#{env_name}", "workflow" => "$#{env_name}"}]
          }
        })

      assert [%Schema.TrackerProject{slug: "alpha", repo: nil, workflow: nil}] = settings.tracker.projects
    end

    test "whitespace-only env values resolve repo to nil" do
      env_name = "SYMPHONY_COVERAGE_BLANK_#{System.unique_integer([:positive])}"
      System.put_env(env_name, "   ")
      on_exit(fn -> System.delete_env(env_name) end)

      settings = parse!(%{"tracker" => %{"projects" => [%{"slug" => "alpha", "repo" => "$#{env_name}"}]}})

      assert [%Schema.TrackerProject{repo: nil}] = settings.tracker.projects
    end
  end

  describe "section validation" do
    test "agent rejects unknown backends" do
      assert parse_error(%{"agent" => %{"backend" => "gpt"}}) =~
               "agent.backend must be one of: codex, opencode, claude"
    end

    test "non-map opencode sections are reported as invalid" do
      assert parse_error(%{"opencode" => "serve"}) =~ "opencode is invalid"
    end

    test "accounts rejects unrecognised boolean strings" do
      assert parse_error(%{"accounts" => %{"enabled" => "maybe"}}) =~ "accounts.enabled is invalid"

      settings = parse!(%{"accounts" => %{"enabled" => " Yes ", "allow_host_auth_fallback" => "off"}})
      assert settings.accounts.enabled == true
      assert settings.accounts.allow_host_auth_fallback == false
    end

    test "accounts changeset passes non-map attrs straight to cast" do
      assert_raise Ecto.CastError, fn ->
        Schema.Accounts.changeset(%Schema.Accounts{}, "not-a-map")
      end
    end

    test "log section validates sizes and resolves an unset dir to nil" do
      assert parse_error(%{"log" => %{"max_files" => 0}}) =~ "log.max_files must be greater than 0"
      assert parse_error(%{"log" => %{"max_bytes" => 0}}) =~ "log.max_bytes must be greater than 0"

      env_name = unset_env_name()

      settings =
        parse!(%{
          "log" => %{"dir" => "$#{env_name}", "file_name" => "  ", "max_bytes" => 1024, "max_files" => 3}
        })

      assert settings.log.dir == nil
      assert settings.log.file_name == "symphony.log"
      assert settings.log.max_bytes == 1024
      assert settings.log.max_files == 3
    end
  end
end
