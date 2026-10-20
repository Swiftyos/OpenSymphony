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
