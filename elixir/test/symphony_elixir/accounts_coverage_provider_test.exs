defmodule SymphonyElixir.AccountsCoverageProviderTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias SymphonyElixir.Accounts

  setup do
    root = temp_dir!("store")
    bin = temp_dir!("bin")
    File.mkdir_p!(bin)
    {:ok, settings: settings(root), root: root, bin: bin}
  end

  describe "verify/4" do
    test "runs provider status commands with isolated credentials", %{settings: settings, bin: bin} do
      {:ok, codex} = Accounts.create_or_update("codex", "v", [email: "v@example.com"], settings)
      {:ok, claude} = Accounts.create_or_update("claude", "v", [], settings)

      codex_cmd = write_exe!(bin, "status-codex", ~s(printf 'args=%s\\nhome=%s\\n' "$*" "$CODEX_HOME"))
      claude_cmd = write_exe!(bin, "status-other", ~s(printf 'args=%s\\ncfg=%s\\n' "$*" "$CLAUDE_CONFIG_DIR"))

      assert {:ok, %{account: summary, output: output}} =
               Accounts.verify("codex", "v", [command: "#{codex_cmd} --profile work"], settings)

      assert summary.id == "v"
      assert summary.email == "v@example.com"
      assert output == "args=--profile work login status\nhome=#{codex.codex_home}"

      assert {:ok, %{output: claude_output}} = Accounts.verify("claude", "v", [command: claude_cmd], settings)
      assert claude_output == "args=auth status --json\ncfg=#{claude.claude_config_dir}"
    end

    test "falls back to the default provider executables on PATH", %{settings: settings, bin: bin} do
      write_exe!(bin, "codex", ~s(printf 'fake codex %s\\n' "$*"))
      write_exe!(bin, "claude", ~s(printf 'fake claude %s\\n' "$*"))
      put_path!(bin <> ":" <> System.get_env("PATH", ""))

      {:ok, _} = Accounts.create_or_update("codex", "d", [], settings)
      {:ok, _} = Accounts.create_or_update("claude", "d", [], settings)

      assert {:ok, %{output: "fake codex login status"}} = Accounts.verify("codex", "d", [], settings)
      assert {:ok, %{output: "fake claude auth status --json"}} = Accounts.verify("claude", "d", [], settings)
    end

    test "reports provider failures", %{settings: settings, bin: bin} do
      {:ok, _} = Accounts.create_or_update("codex", "f", [], settings)
      failing = write_exe!(bin, "status-fail", "printf 'not logged in\\n'\nexit 3")

      assert {:error, %{exit_status: 3, output: "not logged in\n"}} =
               Accounts.verify("codex", "f", [command: failing], settings)

      assert {:error, :missing_provider_command} = Accounts.verify("codex", "f", [command: "   "], settings)

      assert {:error, %ErlangError{original: :enoent}} =
               Accounts.verify("codex", "f", [command: Path.join(bin, "does-not-exist")], settings)

      assert {:error, :not_found} = Accounts.verify("codex", "missing", [command: failing], settings)
    end
  end

  describe "codex login" do
    test "extracts the email from provider output when none is given", %{settings: settings, bin: bin} do
      write_exe!(bin, "login-by-name", "printf 'Successfully logged in as found@example.com\\n'")
      write_exe!(bin, "login-no-email", "printf 'Successfully logged in\\n'")
      put_path!(bin <> ":" <> System.get_env("PATH", ""))

      output =
        capture_io(fn ->
          assert {:ok, account} = Accounts.login("codex", "named", [command: "login-by-name"], settings)
          assert account.email == "found@example.com"
          assert account.credential_kind == "codex_home"

          assert {:ok, anonymous} = Accounts.login("codex", "anon", [command: "login-no-email"], settings)
          assert anonymous.email == nil
        end)

      assert output =~ "Successfully logged in as found@example.com"
    end

    test "returns streaming failures and missing commands", %{settings: settings, bin: bin} do
      failing = write_exe!(bin, "login-fail", "printf 'boom\\n'\nexit 2")

      output =
        capture_io(fn ->
          assert {:error, %{exit_status: 2, output: "boom\n"}} =
                   Accounts.login("codex", "broken", [command: failing], settings)
        end)

      assert output == "boom\n"

      assert {:error, {:provider_command_not_found, "symphony-missing-provider-xyz"}} =
               Accounts.login("codex", "missing", [command: "symphony-missing-provider-xyz"], settings)
    end

    test "pty logins forward sanitized stdin to the provider", %{settings: settings, bin: bin} do
      write_exe!(bin, "script", """
      if [ "$2" = "-c" ]; then exec /bin/sh -c "$3"; fi
      shift 2
      exec "$@"
      """)

      provider =
        write_exe!(bin, "login-interactive", """
        printf '\\033[?2004hcode please\\n'
        IFS= read -r line
        printf 'got:%s\\n' "$line"
        """)

      put_path!(bin <> ":" <> System.get_env("PATH", ""))

      output =
        capture_io("secret\e[200~^[[201~\n", fn ->
          assert {:ok, account} = Accounts.login("codex", "pty", [command: provider, pty: true], settings)
          assert account.credential_kind == "codex_home"
        end)

      assert output =~ "code please"
      assert output =~ "got:secret\n"
      refute output =~ "\e[?2004h"
    end

    test "pty and tty capture need the script command", %{settings: settings, bin: bin} do
      provider = write_exe!(bin, "login-unused", "exit 0")
      {:ok, _} = Accounts.create_or_update("codex", "no-script", [], settings)
      put_path!(temp_dir!("empty-path"))

      assert {:error, :script_command_not_found_for_pty_login} =
               Accounts.login("codex", "no-script", [command: provider, pty: true], settings)

      assert {:error, {:provider_command_not_found, "script"}} =
               Accounts.verify("codex", "no-script", [command: provider, tty_capture: true], settings)
    end
  end

  describe "claude login" do
    test "setup-token failures are returned", %{settings: settings, bin: bin} do
      failing = write_exe!(bin, "setup-fail", "printf 'auth failed\\n'\nexit 1")

      output =
        capture_io(fn ->
          assert {:error, %{exit_status: 1, output: "auth failed\n"}} =
                   Accounts.login("claude", "fail", [command: failing, tty_capture: false], settings)
        end)

      assert output == "auth failed\n"
    end

    test "setup-token output without a token is rejected", %{settings: settings, bin: bin} do
      provider = write_exe!(bin, "setup-empty", "printf 'nothing to see\\n'")

      capture_io(fn ->
        assert {:error, {:missing_claude_oauth_token, "nothing to see\n"}} =
                 Accounts.login("claude", "no-token", [command: provider, tty_capture: false], settings)
      end)
    end

    test "tty capture runs setup-token through script and stores the captured token",
         %{settings: settings, root: root, bin: bin} do
      write_exe!(bin, "script", "exit 0")
      provider = write_exe!(bin, "setup-tty", "exit 0")
      put_path!(bin <> ":" <> System.get_env("PATH", ""))

      transcript = Path.join([root, "claude", "tty", "claude_setup_token.transcript"])

      # `sh -l` sources $HOME/.profile; use it to emit the token and force a zero
      # exit so the outcome does not depend on whether /dev/tty is available.
      put_home_profile!("""
      printf 'sk-ant-oat-ttytoken\\n'
      rm -f '#{transcript}'
      trap 'exit 0' EXIT
      """)

      assert {:ok, account} = Accounts.login("claude", "tty", [command: provider], settings)
      assert account.credential_kind == "claude_oauth_token"
      assert File.read!(account.claude_oauth_token_file) == "sk-ant-oat-ttytoken\n"
      refute File.exists?(transcript)
    end

    test "tty capture reports non-zero exits", %{settings: settings, bin: bin} do
      write_exe!(bin, "script", "exit 7")
      provider = write_exe!(bin, "status-tty", "exit 0")
      put_path!(bin <> ":" <> System.get_env("PATH", ""))
      put_home_profile!(":\n")
      {:ok, _} = Accounts.create_or_update("codex", "tty-fail", [], settings)

      assert {:error, %{exit_status: status, output: output}} =
               Accounts.verify("codex", "tty-fail", [command: provider, tty_capture: true], settings)

      assert status != 0
      assert is_binary(output)
    end
  end

  describe "claude import" do
    test "fails when the source directory has no config files", %{settings: settings} do
      source = temp_dir!("empty-source")
      File.mkdir_p!(source)

      assert {:error, {:missing_claude_config, ^source}} =
               Accounts.import_account("claude", "empty", [from: source], settings)
    end

    test "copies an explicitly configured global config file", %{settings: settings} do
      source = temp_dir!("source")
      File.mkdir_p!(source)
      global = Path.join(temp_dir!("global"), "claude-global.json")
      File.mkdir_p!(Path.dirname(global))
      File.write!(global, ~s({"oauthAccount":{}}))

      assert {:ok, account} =
               Accounts.import_account("claude", "global", [from: source, global_config_file: global], settings)

      assert File.read!(Path.join(account.claude_config_dir, ".claude.json")) == ~s({"oauthAccount":{}})
      assert account.credential_kind == "claude_config"
    end

    test "uses CLAUDE_CONFIG_DIR when no source is given", %{settings: settings} do
      source = temp_dir!("env-source")
      File.mkdir_p!(source)
      File.write!(Path.join(source, "settings.json"), ~s({"theme":"light"}))

      previous = System.get_env("CLAUDE_CONFIG_DIR")
      System.put_env("CLAUDE_CONFIG_DIR", source)
      on_exit(fn -> restore_env("CLAUDE_CONFIG_DIR", previous) end)

      assert {:ok, account} = Accounts.import_account("claude", "env", [], settings)
      assert File.read!(Path.join(account.claude_config_dir, "settings.json")) =~ "light"
    end
  end

  defp settings(store_root) do
    %{
      accounts: %{
        enabled: true,
        store_root: store_root,
        allow_host_auth_fallback: false,
        rotation_strategy: "usage_aware_round_robin",
        max_concurrent_sessions_per_account: 1,
        exhausted_cooldown_ms: 60_000,
        daily_token_budget: nil
      }
    }
  end

  defp write_exe!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o700)
    path
  end

  defp put_path!(path) do
    previous = System.get_env("PATH")
    System.put_env("PATH", path)
    on_exit(fn -> restore_env("PATH", previous) end)
  end

  defp put_home_profile!(profile) do
    home = temp_dir!("home")
    File.mkdir_p!(home)
    File.write!(Path.join(home, ".profile"), profile)
    previous = System.get_env("HOME")
    System.put_env("HOME", home)
    on_exit(fn -> restore_env("HOME", previous) end)
  end

  defp temp_dir!(suffix) do
    dir = Path.join(System.tmp_dir!(), "symphony-accounts-provider-#{suffix}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
