defmodule SymphonyElixir.CodexAppServerTest do
  use SymphonyElixir.TestSupport

  test "codex backend rejects the workspace root and paths outside workspace root" do
    test_root = temp_root!("cwd-guard")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "codex",
        workspace_root: workspace_root
      )

      issue = issue_fixture("MT-999", "Validate workspace guard")

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "codex backend rejects symlink escape cwd paths under the workspace root" do
    test_root = temp_root!("symlink-cwd-guard")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "codex",
        workspace_root: workspace_root
      )

      issue = issue_fixture("MT-1000", "Validate symlink workspace guard")

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               AppServer.run(symlink_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "codex backend passes explicit turn sandbox policies through unchanged" do
    test_root = temp_root!("supported-turn-policies")
    trace_env = "SYMP_TEST_CODEX_TRACE_#{System.unique_integer([:positive])}"
    previous_trace = System.get_env(trace_env)

    on_exit(fn -> restore_env(trace_env, previous_trace) end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-turn-policies.trace")
      File.mkdir_p!(workspace)
      System.put_env(trace_env, trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${#{trace_env}:-/tmp/codex-supported-turn-policies.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1001"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1001"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      issue = issue_fixture("MT-1001", "Validate explicit turn sandbox policy passthrough")

      policy_cases = [
        %{"type" => "dangerFullAccess"},
        %{"type" => "externalSandbox", "profile" => "remote-ci"},
        %{"type" => "workspaceWrite", "writableRoots" => ["relative/path"], "networkAccess" => true},
        %{"type" => "futureSandbox", "nested" => %{"flag" => true}}
      ]

      Enum.each(policy_cases, fn configured_policy ->
        File.rm(trace_file)

        write_workflow_file!(Workflow.workflow_file_path(),
          agent_backend: "codex",
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server",
          codex_turn_sandbox_policy: configured_policy
        )

        assert {:ok, _result} = AppServer.run(workspace, "Validate supported turn policy", issue)

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "turn/start" &&
                       get_in(payload, ["params", "sandboxPolicy"]) == configured_policy
                   end)
                 else
                   false
                 end
               end)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "codex backend appends max effort to the launcher command" do
    test_root = temp_root!("effort")
    trace_env = "SYMP_TEST_CODEX_TRACE_#{System.unique_integer([:positive])}"
    previous_trace = System.get_env(trace_env)

    on_exit(fn -> restore_env(trace_env, previous_trace) end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001-EFFORT")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-effort.trace")
      File.mkdir_p!(workspace)
      System.put_env(trace_env, trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${#{trace_env}:-/tmp/codex-effort.trace}"
      count=0

      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      if [ -n "${OPENROUTER_API_KEY:-}" ]; then
        printf 'ENV:OPENROUTER_API_KEY=%s\\n' "$OPENROUTER_API_KEY" >> "$trace_file"
      fi

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-effort"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-effort"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "codex",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        providers_openrouter_api_key: "openrouter-local-token"
      )

      assert {:ok, _result} =
               AppServer.run(workspace, "Use maximum effort", issue_fixture("MT-1001-EFFORT", "Maximum effort"), effort: "max")

      trace = File.read!(trace_file)
      assert trace =~ "ARGV:app-server -c model_reasoning_effort=xhigh"
      assert trace =~ "ENV:OPENROUTER_API_KEY=openrouter-local-token"
    after
      File.rm_rf(test_root)
    end
  end

  test "codex backend marks request-for-input events as a hard failure" do
    test_root = temp_root!("input")
    trace_env = "SYMP_TEST_CODEX_TRACE_#{System.unique_integer([:positive])}"
    previous_trace = System.get_env(trace_env)

    on_exit(fn -> restore_env(trace_env, previous_trace) end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      File.mkdir_p!(workspace)
      System.put_env(trace_env, trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${#{trace_env}:-/tmp/codex-input.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-88"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-88"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/input_required","id":"resp-1","params":{"requiresInput":true,"reason":"blocked"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "codex",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = issue_fixture("MT-88", "Input needed")

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs input", issue)

      assert payload["method"] == "turn/input_required"
    after
      File.rm_rf(test_root)
    end
  end

  test "codex backend auto-approves command execution approval requests when approval policy is never" do
    test_root = temp_root!("auto-approve")
    trace_env = "SYMP_TEST_CODEX_TRACE_#{System.unique_integer([:positive])}"
    previous_trace = System.get_env(trace_env)

    on_exit(fn -> restore_env(trace_env, previous_trace) end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-auto-approve.trace")
      File.mkdir_p!(workspace)
      System.put_env(trace_env, trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${#{trace_env}:-/tmp/codex-auto-approve.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-89"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-89"}}}'
            printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"gh pr view","cwd":"/tmp","reason":"need approval"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "codex",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = issue_fixture("MT-89", "Auto approve request")

      assert {:ok, _result} = AppServer.run(workspace, "Handle approval request", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 99 and get_in(payload, ["result", "decision"]) == "acceptForSession"
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "codex backend executes supported dynamic tool calls and returns the tool result" do
    test_root = temp_root!("supported-tool-call")
    trace_env = "SYMP_TEST_CODEX_TRACE_#{System.unique_integer([:positive])}"
    previous_trace = System.get_env(trace_env)

    on_exit(fn -> restore_env(trace_env, previous_trace) end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90A")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-tool-call.trace")
      File.mkdir_p!(workspace)
      System.put_env(trace_env, trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${#{trace_env}:-/tmp/codex-supported-tool-call.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-90a"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-90a"}}}'
            printf '%s\\n' '{"id":102,"method":"item/tool/call","params":{"name":"linear_graphql","callId":"call-90a","threadId":"thread-90a","turnId":"turn-90a","arguments":{"query":"query Viewer { viewer { id } }","variables":{"includeTeams":false}}}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "codex",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = issue_fixture("MT-90A", "Supported tool call")
      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => true,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"data":{"viewer":{"id":"usr_123"}}})
            }
          ]
        }
      end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle supported tool calls", issue, tool_executor: tool_executor)

      assert_received {:tool_called, "linear_graphql",
                       %{
                         "query" => "query Viewer { viewer { id } }",
                         "variables" => %{"includeTeams" => false}
                       }}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 102 and
                   get_in(payload, ["result", "success"]) == true and
                   get_in(payload, ["result", "contentItems", Access.at(0), "text"]) ==
                     ~s({"data":{"viewer":{"id":"usr_123"}}})
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "codex backend launches over ssh for remote workers" do
    test_root = temp_root!("remote-ssh")
    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      remote_workspace = "/remote/workspaces/MT-REMOTE"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      count=0
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-remote"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-remote"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "codex",
        workspace_root: "/remote/workspaces",
        codex_command: "fake-remote-codex app-server",
        providers_openrouter_api_key: "openrouter-remote-token"
      )

      issue = issue_fixture("MT-REMOTE", "Run remote app server")

      assert {:ok, _result} =
               AppServer.run(
                 remote_workspace,
                 "Run remote worker",
                 issue,
                 worker_host: "worker-01:2200"
               )

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, &String.starts_with?(&1, "ARGV:"))
      assert argv_line =~ "-T -p 2200 worker-01 bash -lc"
      assert argv_line =~ "cd "
      assert argv_line =~ remote_workspace
      assert argv_line =~ "exec "
      assert argv_line =~ "fake-remote-codex app-server"
      assert argv_line =~ "OPENROUTER_API_KEY"
      assert argv_line =~ "openrouter-remote-token"

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [remote_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace
                 end)
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "codex backend writes .codex/config.toml and injects telemetry env vars when telemetry is enabled" do
    test_root = temp_root!("telemetry")
    trace_env = "SYMP_TEST_CODEX_TRACE_#{System.unique_integer([:positive])}"
    previous_trace = System.get_env(trace_env)

    on_exit(fn -> restore_env(trace_env, previous_trace) end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001-TEL")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-telemetry.trace")
      File.mkdir_p!(workspace)
      System.put_env(trace_env, trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${#{trace_env}:-/tmp/codex-telemetry.trace}"
      count=0

      if [ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]; then
        printf 'ENV:OTEL_RESOURCE_ATTRIBUTES=%s\n' "$OTEL_RESOURCE_ATTRIBUTES" >> "$trace_file"
      fi

      if [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]; then
        printf 'ENV:OTEL_EXPORTER_OTLP_ENDPOINT=%s\n' "$OTEL_EXPORTER_OTLP_ENDPOINT" >> "$trace_file"
      fi

      if [ -n "${OTEL_EXPORTER_OTLP_PROTOCOL:-}" ]; then
        printf 'ENV:OTEL_EXPORTER_OTLP_PROTOCOL=%s\n' "$OTEL_EXPORTER_OTLP_PROTOCOL" >> "$trace_file"
      fi

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-tel"}}}'
            ;;
          3)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-tel"}}}'
            ;;
          4)
            printf '%s\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      issue = issue_fixture("MT-1001-TEL", "Telemetry test")

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "codex",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        telemetry_enabled: true,
        telemetry_otlp_endpoint: "http://localhost:11338",
        telemetry_otlp_protocol: "grpc",
        telemetry_include_traces: true,
        telemetry_include_metrics: true,
        telemetry_include_logs: true,
        telemetry_resource_attributes: %{"environment" => "test"},
        instance_name: "test-instance"
      )

      assert {:ok, _result} = AppServer.run(workspace, "Telemetry test", issue)

      codex_config_path = Path.join(workspace, ".codex/config.toml")
      assert File.exists?(codex_config_path)

      codex_config = File.read!(codex_config_path)
      assert codex_config =~ ~s([otel])
      assert codex_config =~ ~s(exporter = { otlp-grpc = { endpoint = "http://localhost:11338" } })
      assert codex_config =~ ~s(environment = "symphony-MT-1001-TEL")

      trace = File.read!(trace_file)
      assert trace =~ "ENV:OTEL_RESOURCE_ATTRIBUTES="
      assert trace =~ "linear.issue.id=issue-MT-1001-TEL"
      assert trace =~ "linear.issue.identifier=MT-1001-TEL"
      assert trace =~ "symphony.backend=codex"
      assert trace =~ "symphony.instance=test-instance"
      assert trace =~ "environment=test"
      assert trace =~ "ENV:OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:11338"
      assert trace =~ "ENV:OTEL_EXPORTER_OTLP_PROTOCOL=grpc"
    after
      File.rm_rf(test_root)
    end
  end

  test "codex backend preserves a user-authored .codex/config.toml" do
    test_root = temp_root!("telemetry-preserve")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-PRESERVE")
      File.mkdir_p!(Path.join(workspace, ".codex"))

      user_config_path = Path.join(workspace, ".codex/config.toml")
      user_config = ~s([some_user]\nkey = "value"\n)
      File.write!(user_config_path, user_config)

      codex_binary = Path.join(test_root, "fake-codex")
      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-pres"}}}' ;;
          3) printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-pres"}}}' ;;
          4) printf '%s\n' '{"method":"turn/completed"}'; exit 0 ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "codex",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        telemetry_enabled: true,
        telemetry_otlp_endpoint: "http://localhost:11338",
        telemetry_otlp_protocol: "grpc"
      )

      assert {:ok, _result} =
               AppServer.run(workspace, "Preserve test", issue_fixture("MT-PRESERVE", "Preserve"))

      assert File.read!(user_config_path) == user_config
    after
      File.rm_rf(test_root)
    end
  end

  test "codex backend escapes TOML special characters in identifier and endpoint" do
    test_root = temp_root!("telemetry-escape")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-ESC")
      File.mkdir_p!(workspace)

      codex_binary = Path.join(test_root, "fake-codex")
      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-esc"}}}' ;;
          3) printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-esc"}}}' ;;
          4) printf '%s\n' '{"method":"turn/completed"}'; exit 0 ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      issue = %Issue{
        id: "issue-mt-esc",
        identifier: ~s(MT-"E\\SC),
        title: "Escape",
        description: "",
        state: "open",
        url: "",
        labels: []
      }

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "codex",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        telemetry_enabled: true,
        telemetry_otlp_endpoint: ~s(http://"evil"/path),
        telemetry_otlp_protocol: "grpc"
      )

      assert {:ok, _result} = AppServer.run(workspace, "Escape", issue)

      toml = File.read!(Path.join(workspace, ".codex/config.toml"))
      assert toml =~ ~s(environment = "symphony-MT-\\"E\\\\SC")
      assert toml =~ ~s(endpoint = "http://\\"evil\\"/path")
    after
      File.rm_rf(test_root)
    end
  end

  test "codex backend http/json protocol emits json encoding in TOML" do
    test_root = temp_root!("telemetry-json")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-JSON")
      File.mkdir_p!(workspace)

      codex_binary = Path.join(test_root, "fake-codex")
      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-json"}}}' ;;
          3) printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-json"}}}' ;;
          4) printf '%s\n' '{"method":"turn/completed"}'; exit 0 ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_backend: "codex",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        telemetry_enabled: true,
        telemetry_otlp_endpoint: "http://localhost:4318",
        telemetry_otlp_protocol: "http/json"
      )

      assert {:ok, _result} =
               AppServer.run(workspace, "Json encoding", issue_fixture("MT-JSON", "Json"))

      toml = File.read!(Path.join(workspace, ".codex/config.toml"))
      assert toml =~ ~s(otlp-http = { endpoint = "http://localhost:4318", protocol = "json" })
    after
      File.rm_rf(test_root)
    end
  end

  defp issue_fixture(identifier, title) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: title,
      description: "Test issue for #{identifier}",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: ["backend"]
    }
  end

  defp temp_root!(suffix) do
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-codex-app-server-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end
end
