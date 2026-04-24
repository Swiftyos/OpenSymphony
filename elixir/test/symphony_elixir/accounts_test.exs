defmodule SymphonyElixir.AccountsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Accounts

  test "usage-aware selector rotates fairly after filtering unavailable accounts" do
    store_root = temp_accounts_root!("selector")
    settings = accounts_settings!(store_root)

    {:ok, _account_a} =
      Accounts.create_or_update("codex", "a", [email: "a@example.com"], settings)

    {:ok, _account_b} =
      Accounts.create_or_update("codex", "b", [email: "b@example.com"], settings)

    assert {:ok, %{id: "a"}} = Accounts.select_for_dispatch("codex", nil, %{}, settings)
    assert {:ok, %{id: "b"}} = Accounts.select_for_dispatch("codex", nil, %{}, settings)
    assert {:ok, %{id: "a"}} = Accounts.select_for_dispatch("codex", nil, %{}, settings)

    assert {:ok, _paused} = Accounts.pause("codex", "a", [reason: "already maxed out"], settings)
    assert {:ok, %{id: "b"}} = Accounts.select_for_dispatch("codex", nil, %{}, settings)

    running = %{
      "issue-1" => %{backend: "codex", account_id: "b"}
    }

    assert {:error, error} = Accounts.select_for_dispatch("codex", nil, running, settings)
    assert error.reason == "no usable codex accounts"

    assert Enum.any?(error.skipped, &match?(%{account_id: "a", reason: "already maxed out"}, &1))

    assert Enum.any?(
             error.skipped,
             &match?(%{account_id: "b", reason: "account concurrency limit reached"}, &1)
           )
  end

  test "selector skips exhausted accounts until their reset time" do
    store_root = temp_accounts_root!("rate-limit")
    settings = accounts_settings!(store_root)
    reset_at = DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.to_iso8601()

    {:ok, account} =
      Accounts.create_or_update("codex", "limited", [email: "limited@example.com"], settings)

    Accounts.record_rate_limits(
      account,
      %{
        "limit_id" => "codex",
        "primary" => %{"limit" => 100, "remaining" => 0, "reset_at" => reset_at}
      },
      settings
    )

    assert {:ok, updated_account} = Accounts.get("codex", "limited", settings)
    assert Accounts.account_summary(updated_account).latest_reset_at == reset_at

    assert {:error, error} = Accounts.select_for_dispatch("codex", nil, %{}, settings)
    assert error.next_available_at == reset_at
    assert [%{account_id: "limited", reason: reason}] = error.skipped
    assert reason =~ "cooling down until"
  end

  test "least_usage selector picks the account with lowest max(session, weekly) usage" do
    store_root = temp_accounts_root!("least-usage")
    settings = accounts_settings!(store_root, accounts_rotation_strategy: "least_usage")

    future_reset = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

    # Account "a": 80% session usage, 10% weekly -> score 0.80
    {:ok, a} = Accounts.create_or_update("claude", "a", [email: "a@example.com"], settings)

    Accounts.record_rate_limits(
      a,
      %{
        "limit_id" => "claude",
        "session" => %{"limit" => 100, "remaining" => 20, "reset_at" => future_reset},
        "weekly" => %{"limit" => 1_000, "remaining" => 900, "reset_at" => future_reset}
      },
      settings
    )

    # Account "b": 10% session usage, 50% weekly -> score 0.50 (wins)
    {:ok, b} = Accounts.create_or_update("claude", "b", [email: "b@example.com"], settings)

    Accounts.record_rate_limits(
      b,
      %{
        "limit_id" => "claude",
        "session" => %{"limit" => 100, "remaining" => 90, "reset_at" => future_reset},
        "weekly" => %{"limit" => 1_000, "remaining" => 500, "reset_at" => future_reset}
      },
      settings
    )

    # Account "c": 90% session usage, 5% weekly -> score 0.90 (near session exhaustion, avoided)
    {:ok, c} = Accounts.create_or_update("claude", "c", [email: "c@example.com"], settings)

    Accounts.record_rate_limits(
      c,
      %{
        "limit_id" => "claude",
        "session" => %{"limit" => 100, "remaining" => 10, "reset_at" => future_reset},
        "weekly" => %{"limit" => 1_000, "remaining" => 950, "reset_at" => future_reset}
      },
      settings
    )

    # Repeated calls are deterministic — score is stable until usage changes.
    assert {:ok, %{id: "b"}} = Accounts.select_for_dispatch("claude", nil, %{}, settings)
    assert {:ok, %{id: "b"}} = Accounts.select_for_dispatch("claude", nil, %{}, settings)

    # When "b" is taken by a running session, the next pick should be "a" (score 0.80)
    # rather than "c" (score 0.90), proving session usage is respected.
    running = %{"issue-1" => %{backend: "claude", account_id: "b"}}
    assert {:ok, %{id: "a"}} = Accounts.select_for_dispatch("claude", nil, running, settings)

    _ = {a, b, c}
  end

  test "least_usage selector prefers fresh accounts with no rate-limit snapshot" do
    store_root = temp_accounts_root!("least-usage-fresh")
    settings = accounts_settings!(store_root, accounts_rotation_strategy: "least_usage")

    future_reset = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

    {:ok, _fresh} = Accounts.create_or_update("claude", "fresh", [email: "fresh@example.com"], settings)

    {:ok, used} = Accounts.create_or_update("claude", "used", [email: "used@example.com"], settings)

    Accounts.record_rate_limits(
      used,
      %{
        "limit_id" => "claude",
        "session" => %{"limit" => 100, "remaining" => 50, "reset_at" => future_reset},
        "weekly" => %{"limit" => 1_000, "remaining" => 900, "reset_at" => future_reset}
      },
      settings
    )

    assert {:ok, %{id: "fresh"}} = Accounts.select_for_dispatch("claude", nil, %{}, settings)
  end

  test "selector skips accounts over local token budgets" do
    store_root = temp_accounts_root!("budget")
    settings = accounts_settings!(store_root)

    {:ok, account} =
      Accounts.create_or_update("claude", "daily", [daily_token_budget: 10], settings)

    Accounts.record_usage(account, %{input_tokens: 7, output_tokens: 3, total_tokens: 10})

    assert {:error, error} = Accounts.select_for_dispatch("claude", nil, %{}, settings)
    assert [%{account_id: "daily", reason: "daily token budget exhausted"}] = error.skipped
  end

  test "credential env isolates Codex and Claude credentials" do
    store_root = temp_accounts_root!("credentials")
    settings = accounts_settings!(store_root)

    {:ok, codex} = Accounts.create_or_update("codex", "main", [], settings)
    assert [{"CODEX_HOME", codex_home}] = Accounts.credential_env(codex)
    assert codex_home == Path.join(codex.account_dir, "codex_home")

    {:ok, claude} = Accounts.create_or_update("claude", "main", [], settings)
    File.write!(claude.claude_oauth_token_file, "oauth-token\n")
    env = Map.new(Accounts.credential_env(claude))

    assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "oauth-token"
    assert env["CLAUDE_CONFIG_DIR"] == Path.join(claude.account_dir, "claude_config")
    assert env["ANTHROPIC_API_KEY"] == ""
  end

  test "claude import copies active CLI config into an isolated account directory" do
    store_root = temp_accounts_root!("claude-import-store")
    source_dir = temp_accounts_root!("claude-import-source")
    settings = accounts_settings!(store_root)

    File.mkdir_p!(source_dir)
    File.write!(Path.join(source_dir, ".claude.json"), ~s({"oauthAccount":{"emailAddress":"import@example.com"}}))
    File.write!(Path.join(source_dir, ".config.json"), ~s({"primaryApiKey":"oauth"}))
    File.write!(Path.join(source_dir, "settings.json"), ~s({"theme":"dark"}))
    File.write!(Path.join(source_dir, "history.jsonl"), "do not copy\n")

    assert {:ok, account} =
             Accounts.import_account(
               "claude",
               "imported",
               [email: "import@example.com", from: source_dir],
               settings
             )

    assert account.email == "import@example.com"
    assert account.credential_kind == "claude_config"
    assert File.read!(Path.join(account.claude_config_dir, ".claude.json")) =~ "oauthAccount"
    assert File.read!(Path.join(account.claude_config_dir, ".config.json")) =~ "primaryApiKey"
    assert File.read!(Path.join(account.claude_config_dir, "settings.json")) =~ "dark"
    refute File.exists?(Path.join(account.claude_config_dir, "history.jsonl"))

    env = Map.new(Accounts.credential_env(account))
    refute Map.has_key?(env, "CLAUDE_CODE_OAUTH_TOKEN")
    assert env["CLAUDE_CONFIG_DIR"] == Path.join(account.account_dir, "claude_config")
    assert env["ANTHROPIC_API_KEY"] == ""
  end

  test "codex login streams provider output while storing isolated account metadata" do
    store_root = temp_accounts_root!("login-stream")
    settings = accounts_settings!(store_root)
    command = fake_provider_command!("codex-login", "printf 'Visit https://example.test/device\\nLogged in as streamed@example.com\\n'")

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:ok, account} =
                 Accounts.login(
                   "codex",
                   "streamed",
                   [email: "streamed@example.com", command: command],
                   settings
                 )

        assert account.email == "streamed@example.com"
        assert account.codex_home == Path.join(account.account_dir, "codex_home")
      end)

    assert output =~ "Visit https://example.test/device"
    assert output =~ "Logged in as streamed@example.com"
  end

  test "claude login streams setup-token output and stores the emitted oauth token" do
    store_root = temp_accounts_root!("claude-login-stream")
    settings = accounts_settings!(store_root)

    command =
      fake_provider_command!(
        "claude-login",
        """
        if [ -z "${CLAUDE_CONFIG_DIR+x}" ]; then
          printf 'claude_config_dir=unset\\n'
        else
          printf 'claude_config_dir=set\\n'
        fi
        if [ "${ANTHROPIC_API_KEY+x}" = x ] && [ -z "$ANTHROPIC_API_KEY" ]; then
          printf 'anthropic_api_key=blank\\n'
        else
          printf 'anthropic_api_key=not_blank_or_unset\\n'
        fi
        printf 'Open https://claude.ai/login\\nsk-ant-oat-testtoken123\\n'
        """
      )

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:ok, account} =
                 Accounts.login(
                   "claude",
                   "streamed",
                   [email: "claude@example.com", command: command, tty_capture: false],
                   settings
                 )

        assert account.email == "claude@example.com"
        assert File.read!(account.claude_oauth_token_file) == "sk-ant-oat-testtoken123\n"
      end)

    assert output =~ "Open https://claude.ai/login"
    assert output =~ "claude_config_dir=unset"
    assert output =~ "anthropic_api_key=not_blank_or_unset"
  end

  test "rate-limit resets append session and weekly usage period CSV rows" do
    store_root = temp_accounts_root!("usage-periods")
    settings = accounts_settings!(store_root)
    first_session_reset = DateTime.utc_now() |> DateTime.add(5 * 60 * 60, :second) |> DateTime.to_iso8601()
    second_session_reset = DateTime.utc_now() |> DateTime.add(10 * 60 * 60, :second) |> DateTime.to_iso8601()
    first_weekly_reset = DateTime.utc_now() |> DateTime.add(7 * 24 * 60 * 60, :second) |> DateTime.to_iso8601()
    second_weekly_reset = DateTime.utc_now() |> DateTime.add(14 * 24 * 60 * 60, :second) |> DateTime.to_iso8601()

    {:ok, account} =
      Accounts.create_or_update("codex", "history", [email: "history@example.com"], settings)

    Accounts.record_rate_limits(
      account,
      %{
        "limit_id" => "gpt-5",
        "session" => %{"limit" => 100, "remaining" => 25, "reset_at" => first_session_reset},
        "weekly" => %{"limit" => 1_000, "remaining" => 500, "reset_at" => first_weekly_reset}
      },
      settings
    )

    Accounts.record_usage(account, %{input_tokens: 10, output_tokens: 5, total_tokens: 15})

    Accounts.record_rate_limits(
      account,
      %{
        "limit_id" => "gpt-5",
        "session" => %{"limit" => 100, "remaining" => 100, "reset_at" => second_session_reset},
        "weekly" => %{"limit" => 1_000, "remaining" => 1_000, "reset_at" => second_weekly_reset}
      },
      settings
    )

    Accounts.record_usage(account, %{input_tokens: 2, output_tokens: 1, total_tokens: 3})

    {:ok, refreshed_account} = Accounts.get("codex", "history", settings)

    csv = File.read!(Path.join(account.account_dir, "usage_periods.csv"))

    assert csv =~ "logged_at,backend,account_id,account_email,limit_id,bucket,period"
    assert csv =~ ",codex,history,history@example.com,gpt-5,session,session,"
    assert csv =~ "#{first_session_reset},#{second_session_reset},100,25,75,75.00,,10,5,15"
    assert csv =~ ",codex,history,history@example.com,gpt-5,weekly,weekly,"
    assert csv =~ "#{first_weekly_reset},#{second_weekly_reset},1000,500,500,50.00,50.00,10,5,15"

    assert refreshed_account.rate_limit_periods["session"] == %{
             "bucket" => "session",
             "period" => "session",
             "limit_id" => "gpt-5",
             "started_at" => refreshed_account.rate_limit_periods["session"]["started_at"],
             "reset_at" => second_session_reset,
             "last_seen_at" => refreshed_account.rate_limit_periods["session"]["last_seen_at"],
             "limit" => 100,
             "remaining" => 100,
             "input_tokens" => 2,
             "output_tokens" => 1,
             "total_tokens" => 3
           }

    assert refreshed_account.rate_limit_periods["weekly"] == %{
             "bucket" => "weekly",
             "period" => "weekly",
             "limit_id" => "gpt-5",
             "started_at" => refreshed_account.rate_limit_periods["weekly"]["started_at"],
             "reset_at" => second_weekly_reset,
             "last_seen_at" => refreshed_account.rate_limit_periods["weekly"]["last_seen_at"],
             "limit" => 1_000,
             "remaining" => 1_000,
             "input_tokens" => 2,
             "output_tokens" => 1,
             "total_tokens" => 3
           }
  end

  test "primary and secondary rate-limit buckets rotate session and weekly periods from unix reset timestamps" do
    store_root = temp_accounts_root!("usage-periods-unix")
    settings = accounts_settings!(store_root)
    first_session_reset_unix = DateTime.utc_now() |> DateTime.add(5 * 60 * 60, :second) |> DateTime.to_unix()
    second_session_reset_unix = DateTime.utc_now() |> DateTime.add(10 * 60 * 60, :second) |> DateTime.to_unix()
    first_weekly_reset_unix = DateTime.utc_now() |> DateTime.add(7 * 24 * 60 * 60, :second) |> DateTime.to_unix()
    second_weekly_reset_unix = DateTime.utc_now() |> DateTime.add(14 * 24 * 60 * 60, :second) |> DateTime.to_unix()
    first_session_reset = DateTime.from_unix!(first_session_reset_unix) |> DateTime.to_iso8601()
    second_session_reset = DateTime.from_unix!(second_session_reset_unix) |> DateTime.to_iso8601()
    first_weekly_reset = DateTime.from_unix!(first_weekly_reset_unix) |> DateTime.to_iso8601()
    second_weekly_reset = DateTime.from_unix!(second_weekly_reset_unix) |> DateTime.to_iso8601()

    {:ok, account} =
      Accounts.create_or_update("codex", "history-unix", [email: "history-unix@example.com"], settings)

    Accounts.record_rate_limits(
      account,
      %{
        "limitId" => "codex_bengalfox",
        "primary" => %{"limit" => 100, "remaining" => 25, "resetsAt" => first_session_reset_unix},
        "secondary" => %{"limit" => 1_000, "remaining" => 500, "resetsAt" => first_weekly_reset_unix}
      },
      settings
    )

    Accounts.record_usage(account, %{input_tokens: 10, output_tokens: 5, total_tokens: 15})

    Accounts.record_rate_limits(
      account,
      %{
        "limitId" => "codex_bengalfox",
        "primary" => %{"limit" => 100, "remaining" => 100, "resetsAt" => second_session_reset_unix},
        "secondary" => %{"limit" => 1_000, "remaining" => 1_000, "resetsAt" => second_weekly_reset_unix}
      },
      settings
    )

    {:ok, refreshed_account} = Accounts.get("codex", "history-unix", settings)
    csv = File.read!(Path.join(account.account_dir, "usage_periods.csv"))

    assert csv =~ ",codex,history-unix,history-unix@example.com,codex_bengalfox,session,session,"
    assert csv =~ "#{first_session_reset},#{second_session_reset},100,25,75,75.00,,10,5,15"
    assert csv =~ ",codex,history-unix,history-unix@example.com,codex_bengalfox,weekly,weekly,"
    assert csv =~ "#{first_weekly_reset},#{second_weekly_reset},1000,500,500,50.00,50.00,10,5,15"

    assert refreshed_account.rate_limit_periods["session"]["reset_at"] == second_session_reset
    assert refreshed_account.rate_limit_periods["weekly"]["reset_at"] == second_weekly_reset
  end

  defp accounts_settings!(store_root, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          accounts_enabled: true,
          accounts_store_root: store_root,
          accounts_exhausted_cooldown_ms: 60_000
        ],
        overrides
      )
    )

    Config.settings!()
  end

  defp temp_accounts_root!(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-accounts-#{suffix}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp fake_provider_command!(suffix, body) do
    path =
      System.tmp_dir!()
      |> Path.join("symphony-elixir-provider-#{suffix}-#{System.unique_integer([:positive])}")

    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
