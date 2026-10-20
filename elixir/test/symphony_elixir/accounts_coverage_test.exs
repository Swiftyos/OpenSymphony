defmodule SymphonyElixir.AccountsCoverageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Accounts

  describe "configuration access" do
    test "enabled?/0 and store_root/0,1 read the configured workflow settings" do
      root = temp_root!("config")
      write_workflow_file!(Workflow.workflow_file_path(), accounts_enabled: true, accounts_store_root: root)

      assert Accounts.enabled?()
      assert Accounts.store_root() == root
      assert Accounts.store_root(nil) == root
    end

    test "store_root/0 falls back to the default store when settings are invalid" do
      write_workflow_file!(Workflow.workflow_file_path(), accounts_rotation_strategy: "bogus")

      assert {:error, _reason} = Config.settings()
      assert Accounts.store_root() == Path.expand("~/.symphony/accounts")
    end

    test "default-argument entry points use the configured workflow settings" do
      root = temp_root!("defaults")
      write_workflow_file!(Workflow.workflow_file_path(), accounts_enabled: true, accounts_store_root: root)
      settings = Config.settings!()
      {:ok, _account} = Accounts.create_or_update("codex", "dflt", [], settings)

      assert {:ok, [%{id: "dflt"}]} = Accounts.list()
      assert {:ok, %{id: "dflt", state: "paused"}} = Accounts.pause("codex", "dflt")
      assert {:ok, %{id: "dflt", state: "unknown"}} = Accounts.resume("codex", "dflt")
      assert {:ok, %{id: "dflt"}} = Accounts.select_for_dispatch("codex", nil, %{})
      assert {:error, :not_found} = Accounts.verify("codex", "missing")
    end

    test "bare accounts maps are accepted as settings" do
      root = temp_root!("bare")
      settings = %{enabled: true, store_root: root}

      assert Accounts.store_root(settings) == root
      assert {:ok, account} = Accounts.create_or_update("codex", "bare", [], settings)
      assert account.account_dir == Path.join([root, "codex", "bare"])
      assert {:ok, %{id: "bare"}} = Accounts.select_for_dispatch("codex", nil, %{}, settings)
    end
  end

  describe "argument validation" do
    test "backend normalization accepts known backends only" do
      assert Accounts.normalize_backend(nil) == nil
      assert Accounts.normalize_backend(" Codex ") == "codex"
      assert Accounts.normalize_backend("gpt") == nil
      assert Accounts.normalize_backend(:codex) == nil
      assert Accounts.normalize_backend!("CLAUDE") == "claude"

      assert_raise ArgumentError, "account backend must be one of: codex, claude", fn ->
        Accounts.normalize_backend!("gpt")
      end
    end

    test "public operations turn invalid input into error tuples" do
      settings = settings!(temp_root!("validation"))

      assert {:error, :not_found} = Accounts.get("codex", "missing", settings)
      assert {:error, %ArgumentError{}} = Accounts.get("gpt", "x", settings)
      assert {:error, %ArgumentError{}} = Accounts.create_or_update("gpt", "x", [], settings)

      assert {:error, %ArgumentError{message: "account id must not be blank"}} =
               Accounts.create_or_update("codex", "   ", [], settings)

      assert {:error, %ArgumentError{}} = Accounts.login("gpt", "x", [], settings)
      assert {:error, %ArgumentError{}} = Accounts.import_account("gpt", "x", [], settings)

      assert {:error, {:unsupported_account_import_backend, "codex"}} =
               Accounts.import_account("codex", "x", [], settings)

      assert {:error, %ArgumentError{}} = Accounts.remove("gpt", "x", settings)

      assert {:error, :not_found} = Accounts.pause("codex", "missing", [], settings)
      assert {:error, :not_found} = Accounts.resume("codex", "missing", settings)
      assert {:error, :not_found} = Accounts.disable("codex", "missing", settings)
      assert {:error, :not_found} = Accounts.enable("codex", "missing", settings)
    end

    test "remove deletes the account directory" do
      settings = settings!(temp_root!("remove"))
      {:ok, account} = Accounts.create_or_update("claude", "gone", [], settings)
      assert File.dir?(account.account_dir)

      assert {:ok, _removed} = Accounts.remove("claude", "gone", settings)
      refute File.exists?(account.account_dir)
      assert {:error, :not_found} = Accounts.get("claude", "gone", settings)
    end
  end

  describe "account lifecycle" do
    test "pause, resume, disable and enable update metadata and effective state" do
      settings = settings!(temp_root!("lifecycle"))
      {:ok, _account} = Accounts.create_or_update("codex", "life", [email: "life@example.com"], settings)
      future = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.truncate(:second)

      assert {:ok, paused} = Accounts.pause("codex", "life", [until: future, reason: "quota"], settings)
      assert paused.state == "paused"
      assert paused.paused_until == DateTime.to_iso8601(future)
      assert paused.paused_reason == "quota"
      assert paused.failure_reason == "quota"

      assert {:ok, resumed} = Accounts.resume("codex", "life", settings)
      assert resumed.state == "unknown"
      assert resumed.paused_until == nil
      assert resumed.paused_reason == nil
      assert resumed.failure_reason == nil
      assert resumed.enabled == true

      assert {:ok, disabled} = Accounts.disable("codex", "life", settings)
      assert disabled.enabled == false
      assert disabled.state == "disabled"

      assert {:ok, enabled} = Accounts.enable("codex", "life", settings)
      assert enabled.enabled == true
      assert enabled.state == "unknown"
    end

    test "pause normalizes the different until formats" do
      settings = settings!(temp_root!("pause-formats"))
      {:ok, _account} = Accounts.create_or_update("codex", "p", [], settings)

      assert {:ok, %{paused_until: "2023-11-14T22:13:20Z", state: "unknown"}} =
               Accounts.pause("codex", "p", [until: "1700000000"], settings)

      assert {:ok, %{paused_until: "2023-11-14T22:13:20Z"}} =
               Accounts.pause("codex", "p", [until: 1_700_000_000], settings)

      huge = 100_000_000_000_000_000_000

      assert {:ok, %{paused_until: paused_until}} = Accounts.pause("codex", "p", [until: huge], settings)
      assert paused_until == Integer.to_string(huge)

      assert {:ok, %{paused_until: "next tuesday"}} =
               Accounts.pause("codex", "p", [until: "next tuesday"], settings)

      assert {:ok, %{paused_until: nil, state: "paused", paused_reason: "manually paused"}} =
               Accounts.pause("codex", "p", [until: "   "], settings)
    end
  end

  describe "selection" do
    test "selection without accounts depends on host auth fallback" do
      root = temp_root!("empty")

      assert {:error, error} = Accounts.select_for_dispatch("codex", nil, %{}, settings!(root))
      assert error.reason == "no configured codex accounts"
      assert error.skipped == []
      assert error.next_available_at == nil

      fallback = settings!(root, allow_host_auth_fallback: true)
      assert {:ok, nil} = Accounts.select_for_dispatch("codex", nil, %{}, fallback)

      disabled = settings!(root, enabled: false)
      assert {:ok, nil} = Accounts.select_for_dispatch("codex", nil, %{}, disabled)
    end

    test "selection only considers accounts bound to the requested worker host" do
      settings = settings!(temp_root!("hosts"))
      {:ok, _local} = Accounts.create_or_update("codex", "local", [], settings)
      {:ok, _remote} = Accounts.create_or_update("codex", "remote", [worker_host: "worker-1"], settings)

      assert {:ok, %{id: "remote"}} = Accounts.select_for_dispatch("codex", "worker-1", %{}, settings)
      assert {:ok, %{id: "local"}} = Accounts.select_for_dispatch("codex", nil, %{}, settings)

      assert {:error, %{reason: "no configured codex accounts"}} =
               Accounts.select_for_dispatch("codex", "worker-2", %{}, settings)
    end

    test "running entries for other backends or without account ids do not count" do
      settings = settings!(temp_root!("running"))
      {:ok, _account} = Accounts.create_or_update("claude", "only", [], settings)

      running = %{
        "a" => %{backend: "codex", account_id: "only"},
        "b" => %{backend: "claude", account_id: nil},
        "c" => :not_a_map
      }

      assert {:ok, %{id: "only"}} = Accounts.select_for_dispatch("claude", nil, running, settings)
    end

    test "paused accounts report reasons derived from their pause metadata" do
      root = temp_root!("paused-reasons")
      settings = settings!(root)
      future = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.truncate(:second)
      future_iso = DateTime.to_iso8601(future)

      {:ok, until_account} = Accounts.create_or_update("codex", "a-until", [], settings)
      {:ok, _} = Accounts.pause("codex", "a-until", [until: future], settings)
      update_json!(until_account.account_dir, "metadata.json", &Map.delete(&1, "paused_reason"))

      {:ok, state_account} = Accounts.create_or_update("codex", "b-state", [], settings)
      update_json!(state_account.account_dir, "state.json", &Map.put(&1, "state", "paused"))

      {:ok, odd_account} = Accounts.create_or_update("codex", "c-odd", [email: "   "], settings)
      update_json!(odd_account.account_dir, "metadata.json", &Map.put(&1, "paused_reason", 123))
      update_json!(odd_account.account_dir, "state.json", &Map.put(&1, "state", "paused"))

      {:ok, disabled_account} = Accounts.create_or_update("codex", "d-disabled", [], settings)
      update_json!(disabled_account.account_dir, "state.json", &Map.put(&1, "state", "disabled"))

      assert {:error, error} = Accounts.select_for_dispatch("codex", nil, %{}, settings)

      assert error.skipped == [
               %{account_id: "a-until", email: nil, reason: "paused until #{future_iso}"},
               %{account_id: "b-state", email: nil, reason: "paused"},
               %{account_id: "c-odd", email: nil, reason: 123},
               %{account_id: "d-disabled", email: nil, reason: "disabled"}
             ]

      assert error.next_available_at == future_iso
    end

    test "malformed state values are tolerated during selection" do
      settings = settings!(temp_root!("malformed-state"), daily_token_budget: 10)
      {:ok, account} = Accounts.create_or_update("claude", "odd", [], settings)

      update_json!(account.account_dir, "state.json", fn state ->
        state
        |> Map.put("state", "mystery")
        |> Map.put("exhausted_until", "not-a-timestamp")
        |> Map.put("token_totals", "junk")
      end)

      assert {:ok, %{id: "odd", state: "unknown", token_totals: "junk"}} =
               Accounts.select_for_dispatch("claude", nil, %{}, settings)
    end
  end

  describe "account storage" do
    test "non-map metadata falls back to defaults derived from the directory" do
      root = temp_root!("non-map")
      settings = settings!(root)
      dir = Path.join([root, "codex", "fromdir"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "metadata.json"), "[]")

      assert {:ok, account} = Accounts.get("codex", "fromdir", settings)
      assert account.id == "fromdir"
      assert account.enabled == true
      assert account.credential_kind == "codex_home"
      assert account.state == "unknown"
    end

    test "accounts with unreadable state are skipped" do
      root = temp_root!("bad-state")
      settings = settings!(root)

      {:ok, invalid} = Accounts.create_or_update("codex", "invalid", [], settings)
      File.write!(Path.join(invalid.account_dir, "state.json"), "{not json")

      {:ok, directory} = Accounts.create_or_update("codex", "directory", [], settings)
      state_path = Path.join(directory.account_dir, "state.json")
      File.rm!(state_path)
      File.mkdir_p!(state_path)

      assert {:error, :not_found} = Accounts.get("codex", "invalid", settings)
      assert {:error, :not_found} = Accounts.get("codex", "directory", settings)
      assert {:ok, []} = Accounts.list("codex", settings)
    end

    test "listing raises when the backend path is not a directory" do
      root = temp_root!("not-dir")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "codex"), "file")

      assert_raise File.Error, ~r/list account directory/, fn ->
        Accounts.list("codex", settings!(root))
      end
    end
  end

  describe "credentials and summaries" do
    test "credential_env ignores unknown account shapes" do
      assert Accounts.credential_env(nil) == []
      assert Accounts.credential_env(%{backend: "codex", codex_home: nil}) == []
      assert Accounts.credential_env(%{backend: "gpt"}) == []
      assert Accounts.account_summary(nil) == nil
      assert %{usage_periods_csv: nil, latest_reset_at: nil} = Accounts.account_summary(%{id: "loose"})
      assert Accounts.quota_error?({:error, "HTTP 429 Too Many Requests"})
      refute Accounts.quota_error?({:error, :timeout})
    end
  end

  describe "usage bookkeeping" do
    test "nil accounts and payloads are no-ops" do
      write_workflow_file!(Workflow.workflow_file_path(), accounts_store_root: temp_root!("noop"))

      assert :ok = Accounts.record_rate_limits(nil, %{})
      assert :ok = Accounts.record_rate_limits(%{account_dir: "/nonexistent"}, nil)
      assert :ok = Accounts.record_usage(nil, %{})
      assert :ok = Accounts.record_usage(%{account_dir: "/nonexistent"}, nil)
      assert :ok = Accounts.mark_exhausted(nil, :quota)
      assert :ok = Accounts.mark_success(nil)
    end

    test "mark_exhausted and mark_success update the stored state" do
      root = temp_root!("marks")

      write_workflow_file!(Workflow.workflow_file_path(),
        accounts_store_root: root,
        accounts_exhausted_cooldown_ms: 60_000
      )

      settings = Config.settings!()
      {:ok, account} = Accounts.create_or_update("codex", "marks", [], settings)

      assert :ok = Accounts.mark_exhausted(account, {:error, "rate limit"})
      {:ok, exhausted} = Accounts.get("codex", "marks", settings)
      assert exhausted.state == "exhausted"
      assert exhausted.failure_reason == ~s({:error, "rate limit"})
      assert {:ok, until, _} = DateTime.from_iso8601(exhausted.exhausted_until)
      assert DateTime.diff(until, DateTime.utc_now(), :second) in 50..60

      assert :ok = Accounts.mark_success(account)
      {:ok, still_exhausted} = Accounts.get("codex", "marks", settings)
      assert still_exhausted.state == "exhausted"
      assert is_binary(still_exhausted.last_success_at)

      update_json!(account.account_dir, "state.json", &Map.put(&1, "state", "limited"))
      assert :ok = Accounts.mark_success(account, settings)
      assert {:ok, %{state: "healthy"}} = Accounts.get("codex", "marks", settings)
    end

    test "record_usage tolerates malformed rate-limit periods" do
      settings = settings!(temp_root!("usage-periods"))
      {:ok, account} = Accounts.create_or_update("codex", "u", [], settings)
      update_json!(account.account_dir, "state.json", &Map.put(&1, "rate_limit_periods", "junk"))

      assert :ok = Accounts.record_usage(account, %{input_tokens: 2, output_tokens: 1, total_tokens: 3})
      {:ok, updated} = Accounts.get("codex", "u", settings)
      assert updated.rate_limit_periods == %{}
      assert updated.token_totals["total"]["total_tokens"] == 3
    end
  end

  describe "rate limit interpretation" do
    test "exhaustion without a reset time falls back to the cooldown" do
      settings = settings!(temp_root!("cooldown"), exhausted_cooldown_ms: 120_000)
      {:ok, account} = Accounts.create_or_update("codex", "cool", [], settings)

      assert :ok = Accounts.record_rate_limits(account, %{"primary" => %{"remaining" => 0}}, settings)
      {:ok, updated} = Accounts.get("codex", "cool", settings)

      assert updated.state == "exhausted"
      assert updated.failure_reason == "rate limits exhausted"
      assert {:ok, until, _} = DateTime.from_iso8601(updated.exhausted_until)
      assert DateTime.diff(until, DateTime.utc_now(), :second) in 110..120
    end

    test "low remaining capacity marks the account limited" do
      settings = settings!(temp_root!("limited"))
      {:ok, account} = Accounts.create_or_update("codex", "low", [], settings)

      rate_limits = %{"session" => %{"limit" => 100, "remaining" => 5}}
      assert :ok = Accounts.record_rate_limits(account, rate_limits, settings)
      assert {:ok, %{state: "limited", exhausted_until: nil}} = Accounts.get("codex", "low", settings)
    end

    test "atom keyed buckets with string numbers and camelCase resets are understood" do
      settings = settings!(temp_root!("atoms"))
      {:ok, account} = Accounts.create_or_update("codex", "atoms", [], settings)
      reset = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      rate_limits = %{
        limitName: "codex_atoms",
        primary: %{remaining: "0", limit: "100", resetsAt: reset},
        secondary: %{remaining: "-5", limit: "50", resetsAt: reset}
      }

      assert :ok = Accounts.record_rate_limits(account, rate_limits, settings)
      {:ok, updated} = Accounts.get("codex", "atoms", settings)

      assert updated.state == "exhausted"
      assert updated.exhausted_until == reset
      assert %{"session" => session, "weekly" => weekly} = updated.rate_limit_periods
      assert session["limit_id"] == "codex_atoms"
      assert session["limit"] == 100
      assert session["remaining"] == 0
      assert weekly["remaining"] == 0
      assert Accounts.account_summary(updated).latest_reset_at == reset
    end

    test "relative reset values are converted into absolute timestamps" do
      settings = settings!(temp_root!("relative"))
      {:ok, account} = Accounts.create_or_update("codex", "rel", [], settings)

      rate_limits = %{secondary: %{remaining: 0, reset_after_seconds: 90}}
      assert :ok = Accounts.record_rate_limits(account, rate_limits, settings)
      {:ok, updated} = Accounts.get("codex", "rel", settings)

      assert updated.state == "exhausted"
      assert {:ok, until, _} = DateTime.from_iso8601(updated.exhausted_until)
      assert DateTime.diff(until, DateTime.utc_now(), :second) in 80..90
    end

    test "string relative resets, float limits and used percentages are understood" do
      settings = settings!(temp_root!("relative-string"))
      {:ok, account} = Accounts.create_or_update("codex", "rel-s", [], settings)

      rate_limits = %{"primary" => %{"usedPercent" => 100.0, "limit" => 100.0, "reset_in_seconds" => 45}}
      assert :ok = Accounts.record_rate_limits(account, rate_limits, settings)
      {:ok, updated} = Accounts.get("codex", "rel-s", settings)

      assert updated.state == "exhausted"
      assert {:ok, until, _} = DateTime.from_iso8601(updated.exhausted_until)
      assert DateTime.diff(until, DateTime.utc_now(), :second) in 35..45

      assert :ok = Accounts.record_rate_limits(account, %{"primary" => %{"usedPercent" => 42}}, settings)
      assert {:ok, %{state: "healthy"}} = Accounts.get("codex", "rel-s", settings)
    end

    test "credit balances decide exhaustion when buckets have capacity" do
      settings = settings!(temp_root!("credits"))
      {:ok, account} = Accounts.create_or_update("codex", "credits", [], settings)

      cases = [
        {%{"unlimited" => true, "balance" => 0}, "healthy"},
        {%{has_credits: false}, "exhausted"},
        # String keys, as decoded from provider JSON (was missed: `false || nil` is nil).
        {%{"has_credits" => false}, "exhausted"},
        {%{"has_credits" => true, "unlimited" => false}, "healthy"},
        {%{balance: 0}, "exhausted"},
        {%{"balance" => 12.5}, "healthy"},
        {%{"balance" => "0.00"}, "exhausted"},
        {%{"balance" => "4.20"}, "healthy"},
        {%{"balance" => "not-a-number"}, "healthy"},
        {%{}, "healthy"}
      ]

      for {credits, expected_state} <- cases do
        rate_limits = %{"credits" => credits}
        assert :ok = Accounts.record_rate_limits(account, rate_limits, settings)
        {:ok, updated} = Accounts.get("codex", "credits", settings)
        assert {credits, updated.state} == {credits, expected_state}
      end

      assert :ok = Accounts.record_rate_limits(account, %{credits: %{"balance" => 0}}, settings)
      assert {:ok, %{state: "exhausted"}} = Accounts.get("codex", "credits", settings)
    end

    test "period names are condensed from bucket metadata" do
      settings = settings!(temp_root!("period-names"))
      {:ok, account} = Accounts.create_or_update("claude", "names", [], settings)
      reset = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      rate_limits = %{
        "session" => %{"name" => "hourly", "limit" => 10, "remaining" => 9, "reset_at" => reset},
        "weekly" => %{"window" => "monthly", "limit" => 10, "remaining" => 9, "reset_at" => reset}
      }

      assert :ok = Accounts.record_rate_limits(account, rate_limits, settings)
      {:ok, updated} = Accounts.get("claude", "names", settings)
      assert updated.rate_limit_periods["session"]["period"] == "session"
      assert updated.rate_limit_periods["weekly"]["period"] == "weekly"

      blank = %{"session" => %{"period" => "", "limit" => 10, "remaining" => 9, "reset_at" => reset}}
      {:ok, other} = Accounts.create_or_update("claude", "blank", [], settings)
      assert :ok = Accounts.record_rate_limits(other, blank, settings)
      {:ok, blank_account} = Accounts.get("claude", "blank", settings)
      assert blank_account.rate_limit_periods["session"]["period"] == "session"
    end

    test "repeated reset times refresh the current period without rotating" do
      settings = settings!(temp_root!("refresh"))
      {:ok, account} = Accounts.create_or_update("codex", "refresh", [], settings)
      reset = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      first = %{"limit_id" => "first", "primary" => %{"limit" => 100, "remaining" => 60, "reset_at" => reset}}
      assert :ok = Accounts.record_rate_limits(account, first, settings)

      second = %{"primary" => %{"remaining" => 40, "reset_at" => reset}}
      assert :ok = Accounts.record_rate_limits(account, second, settings)

      {:ok, updated} = Accounts.get("codex", "refresh", settings)
      period = updated.rate_limit_periods["session"]
      assert period["limit_id"] == "first"
      assert period["limit"] == 100
      assert period["remaining"] == 40
      refute File.exists?(Path.join(account.account_dir, "usage_periods.csv"))
    end

    test "rotated periods append CSV rows, quoting values and skipping repeated headers" do
      settings = settings!(temp_root!("csv"))
      {:ok, account} = Accounts.create_or_update("codex", "csv", [email: "csv@example.com"], settings)
      [r1, r2, r3] = Enum.map([600, 1_200, 1_800], &future_iso/1)

      assert :ok = Accounts.record_rate_limits(account, %{"limit_id" => "a,b", "primary" => %{"reset_at" => r1}}, settings)
      assert :ok = Accounts.record_rate_limits(account, %{"limit_id" => "a,b", "primary" => %{"reset_at" => r2}}, settings)
      assert :ok = Accounts.record_rate_limits(account, %{"limit_id" => "a,b", "primary" => %{"reset_at" => r3}}, settings)

      csv = File.read!(Path.join(account.account_dir, "usage_periods.csv"))
      [header | rows] = String.split(csv, "\n", trim: true)

      assert header =~ "logged_at,backend,account_id"
      assert length(rows) == 2
      refute Enum.any?(rows, &String.starts_with?(&1, "logged_at"))
      assert Enum.all?(rows, &(&1 =~ ~s(,codex,csv,csv@example.com,"a,b",session,session,)))
      assert Enum.at(rows, 0) =~ "#{r1},#{r2},0,0,0,,,0,0,0"
    end

    test "CSV append failures are logged without failing the update" do
      root = temp_root!("csv-fail")
      settings = settings!(root)
      [r1, r2] = Enum.map([600, 1_200], &future_iso/1)

      for {id, label} <- [{"named", "codex:named"}, {123, "unknown"}] do
        dir = Path.join(root, "custom-#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)

        state = %{"rate_limit_periods" => %{"session" => %{"bucket" => "session", "period" => "session", "reset_at" => r1}}}
        File.write!(Path.join(dir, "state.json"), Jason.encode!(state))

        account = %{backend: "codex", id: id, email: %{not: "printable"}, account_dir: dir}

        log =
          capture_log(fn ->
            assert :ok = Accounts.record_rate_limits(account, %{"primary" => %{"reset_at" => r2}}, settings)
          end)

        assert log =~ "Failed to append account usage period CSV for #{label}"
        stored = dir |> Path.join("state.json") |> File.read!() |> Jason.decode!()
        assert stored["rate_limit_periods"]["session"]["reset_at"] == r2
      end
    end
  end

  defp future_iso(seconds) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp settings!(store_root, overrides \\ []) do
    accounts =
      Map.merge(
        %{
          enabled: true,
          store_root: store_root,
          allow_host_auth_fallback: false,
          rotation_strategy: "usage_aware_round_robin",
          max_concurrent_sessions_per_account: 1,
          exhausted_cooldown_ms: 60_000,
          daily_token_budget: nil
        },
        Map.new(overrides)
      )

    %{accounts: accounts}
  end

  defp update_json!(dir, file, fun) do
    path = Path.join(dir, file)
    updated = path |> File.read!() |> Jason.decode!() |> fun.()
    File.write!(path, Jason.encode!(updated))
  end

  defp temp_root!(suffix) do
    root = Path.join(System.tmp_dir!(), "symphony-accounts-coverage-#{suffix}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
