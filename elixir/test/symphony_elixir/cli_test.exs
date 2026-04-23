defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_symphony_config_file_path: fn _path ->
        send(parent, :config_set)
        :ok
      end,
      validate_config: fn ->
        send(parent, :validated)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Configured agent backends may run without the usual guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :config_set
    refute_received :validated
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to symphony.yml when config path is missing" do
    parent = self()

    deps = %{
      file_regular?: fn path ->
        send(parent, {:config_checked, path})
        Path.basename(path) == "symphony.yml"
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_symphony_config_file_path: fn path ->
        send(parent, {:config_set, path})
        :ok
      end,
      validate_config: fn ->
        send(parent, :validated)
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
    assert_received {:config_checked, path}
    assert Path.basename(path) == "symphony.yml"
    assert_received {:config_set, ^path}
    assert_received :validated
    refute_received :workflow_set
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_symphony_config_file_path: fn _path ->
        send(parent, :config_set)
        :ok
      end,
      validate_config: fn ->
        send(parent, :validated)
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
    assert_received :validated
    refute_received :config_set
  end

  test "uses an explicit symphony config path override when provided" do
    parent = self()
    config_path = "tmp/custom/symphony.yml"
    expanded_path = Path.expand(config_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:config_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_symphony_config_file_path: fn path ->
        send(parent, {:config_set, path})
        :ok
      end,
      validate_config: fn ->
        send(parent, :validated)
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, config_path], deps)
    assert_received {:config_checked, ^expanded_path}
    assert_received {:config_set, ^expanded_path}
    assert_received :validated
    refute_received :workflow_set
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_symphony_config_file_path: fn _path -> :ok end,
      validate_config: fn -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_symphony_config_file_path: fn _path -> :ok end,
      validate_config: fn -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Config file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_symphony_config_file_path: fn _path -> :ok end,
      validate_config: fn -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with config"
    assert message =~ ":boom"
  end

  test "returns validation error before app startup when config is invalid" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_symphony_config_file_path: fn _path -> :ok end,
      validate_config: fn ->
        send(parent, :validated)
        {:error, {:invalid_workflow_config, "projects \"project-a\" workflow invalid"}}
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Invalid Symphony config"
    assert message =~ ~s(projects "project-a" workflow invalid)
    assert_received :workflow_set
    assert_received :validated
    refute_received :started
  end

  test "returns a clear missing Linear token error before app startup" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_symphony_config_file_path: fn _path -> :ok end,
      validate_config: fn -> {:error, :missing_linear_api_token} end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "symphony.yml"], deps)
    assert message =~ "Invalid Symphony config"
    assert message =~ "Linear API token missing"
    assert message =~ "LINEAR_API_KEY"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_symphony_config_file_path: fn _path -> :ok end,
      validate_config: fn -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end

  test "accounts login bypasses guardrails and passes provider options" do
    parent = self()

    deps = %{
      accounts_login: fn backend, id, opts ->
        send(parent, {:login, backend, id, opts})
        {:ok, %{backend: backend, id: id, email: Keyword.get(opts, :email)}}
      end
    }

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = CLI.evaluate(["accounts", "login", "codex", "primary", "--email", "me@example.com"], deps)
      end)

    assert_received {:login, "codex", "primary", [email: "me@example.com"]}
    assert output =~ "Stored codex account primary (me@example.com)"
  end

  test "accounts login accepts trailing config path without starting the app" do
    parent = self()
    config_path = Path.expand("../../symphony-s2t.yml")

    deps = %{
      file_regular?: fn path ->
        send(parent, {:file_checked, path})
        path == config_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_symphony_config_file_path: fn path ->
        send(parent, {:config_set, path})
        :ok
      end,
      accounts_login: fn backend, id, opts ->
        send(parent, {:login, backend, id, opts})
        {:ok, %{backend: backend, id: id, email: Keyword.get(opts, :email)}}
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok =
                 CLI.evaluate(
                   ["accounts", "login", "codex", "primary", "--email", "me@example.com", "../../symphony-s2t.yml"],
                   deps
                 )
      end)

    assert_received {:file_checked, ^config_path}
    assert_received {:config_set, ^config_path}
    refute_received {:workflow_set, _path}
    refute_received :started
    assert_received {:login, "codex", "primary", [email: "me@example.com"]}
    assert output =~ "Stored codex account primary (me@example.com)"
  end

  test "accounts login can read a Claude token from stdin" do
    parent = self()

    deps = %{
      accounts_login: fn backend, id, opts ->
        send(parent, {:login, backend, id, opts})
        {:ok, %{backend: backend, id: id, email: Keyword.get(opts, :email)}}
      end
    }

    output =
      ExUnit.CaptureIO.capture_io("sk-ant-oat-secret\n", fn ->
        assert :ok =
                 CLI.evaluate(
                   ["accounts", "login", "claude", "work", "--email", "work@example.com", "--token-stdin"],
                   deps
                 )
      end)

    assert_received {:login, "claude", "work", opts}
    assert Keyword.get(opts, :email) == "work@example.com"
    assert Keyword.get(opts, :token) == "sk-ant-oat-secret"
    refute Keyword.has_key?(opts, :token_stdin)
    assert output =~ "Stored claude account work (work@example.com)"
  end

  test "accounts import passes Claude source options without starting the app" do
    parent = self()
    config_path = Path.expand("../../symphony-s2t.yml")
    source_path = Path.expand("~/.claude-work")

    deps = %{
      file_regular?: fn path ->
        send(parent, {:file_checked, path})
        path == config_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_symphony_config_file_path: fn path ->
        send(parent, {:config_set, path})
        :ok
      end,
      accounts_import: fn backend, id, opts ->
        send(parent, {:import, backend, id, opts})
        {:ok, %{backend: backend, id: id, email: Keyword.get(opts, :email)}}
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok =
                 CLI.evaluate(
                   [
                     "accounts",
                     "import",
                     "claude",
                     "work",
                     "--email",
                     "work@example.com",
                     "--from",
                     source_path,
                     "../../symphony-s2t.yml"
                   ],
                   deps
                 )
      end)

    assert_received {:file_checked, ^config_path}
    assert_received {:config_set, ^config_path}
    refute_received {:workflow_set, _path}
    refute_received :started
    assert_received {:import, "claude", "work", [email: "work@example.com", from: ^source_path]}
    assert output =~ "Imported claude account work (work@example.com)"
  end

  test "accounts list formats account health without secrets" do
    deps = %{
      accounts_list: fn backend ->
        assert backend == "claude"

        {:ok,
         [
           %{
             backend: "claude",
             id: "work",
             email: "work@example.com",
             state: "paused",
             credential_kind: "claude_oauth_token",
             failure_reason: "daily quota exhausted"
           }
         ]}
      end
    }

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = CLI.evaluate(["accounts", "list", "claude"], deps)
      end)

    assert output =~ "claude\twork\twork@example.com\tpaused\tclaude_oauth_token\tdaily quota exhausted"
  end
end
