defmodule SymphonyElixir.MetricsControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn

  alias SymphonyElixir.{Accounts, Config}

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "GET /metrics returns current rate-limit metrics plus active and closed usage periods" do
    store_root = temp_accounts_root!("metrics")
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

    start_test_endpoint()

    conn = get(build_conn(), "/metrics")
    body = response(conn, 200)

    assert ["text/plain; version=0.0.4; charset=utf-8"] = get_resp_header(conn, "content-type")
    assert body =~ "# HELP symphony_account_rate_limit_limit Current account rate-limit bucket limit."
    assert body =~ "# TYPE symphony_account_usage_period_tokens gauge"

    assert body =~
             ~s(symphony_account_state_info{backend="codex",account_id="history",account_email="history@example.com",state="healthy",credential_kind="codex_home"} 1)

    assert body =~
             ~s(symphony_account_rate_limit_limit{backend="codex",account_id="history",account_email="history@example.com",limit_id="gpt-5",bucket="session"} 100)

    assert body =~
             ~s(symphony_account_rate_limit_remaining{backend="codex",account_id="history",account_email="history@example.com",limit_id="gpt-5",bucket="weekly"} 1000)

    assert body =~
             ~s(bucket="session",period="session",period_started_at=")

    assert body =~ ~s(reset_at="#{second_session_reset}",period_status="active",token_type="total"} 3)
    assert body =~ ~s(reset_at="#{second_weekly_reset}",period_status="active",token_type="input"} 2)
    assert body =~ ~s(reset_at="#{first_session_reset}",period_status="closed",token_type="total"} 15)
    assert body =~ ~s(reset_at="#{first_weekly_reset}",period_status="closed"} 50.00)
  end

  test "GET /metrics exposes codex-style primary and secondary buckets as session and weekly" do
    store_root = temp_accounts_root!("metrics-codex-shape")
    settings = accounts_settings!(store_root)
    session_reset = DateTime.utc_now() |> DateTime.add(5 * 60 * 60, :second) |> DateTime.to_unix()
    weekly_reset = DateTime.utc_now() |> DateTime.add(7 * 24 * 60 * 60, :second) |> DateTime.to_unix()

    {:ok, account} =
      Accounts.create_or_update("codex", "work", [email: "work@example.com"], settings)

    Accounts.record_rate_limits(
      account,
      %{
        "limitId" => "codex_bengalfox",
        "primary" => %{"usedPercent" => 12, "resetsAt" => session_reset},
        "secondary" => %{"usedPercent" => 34.5, "resetsAt" => weekly_reset}
      },
      settings
    )

    start_test_endpoint()

    conn = get(build_conn(), "/metrics")
    body = response(conn, 200)

    assert body =~
             ~s(symphony_account_rate_limit_usage_percent{backend="codex",account_id="work",account_email="work@example.com",limit_id="codex_bengalfox",bucket="session"} 12.00)

    assert body =~
             ~s(symphony_account_rate_limit_usage_percent{backend="codex",account_id="work",account_email="work@example.com",limit_id="codex_bengalfox",bucket="weekly"} 34.50)

    assert body =~
             ~s(symphony_account_rate_limit_reset_timestamp_seconds{backend="codex",account_id="work",account_email="work@example.com",limit_id="codex_bengalfox",bucket="session"} #{session_reset})

    assert body =~
             ~s(symphony_account_rate_limit_reset_timestamp_seconds{backend="codex",account_id="work",account_email="work@example.com",limit_id="codex_bengalfox",bucket="weekly"} #{weekly_reset})
  end

  test "GET /metrics backfills active usage periods from latest rate limits when persisted periods are missing" do
    store_root = temp_accounts_root!("metrics-codex-fallback")
    settings = accounts_settings!(store_root)
    session_reset = DateTime.utc_now() |> DateTime.add(5 * 60 * 60, :second) |> DateTime.to_unix()
    weekly_reset = DateTime.utc_now() |> DateTime.add(7 * 24 * 60 * 60, :second) |> DateTime.to_unix()
    session_started_at = DateTime.from_unix!(session_reset - 300 * 60) |> DateTime.to_iso8601()
    weekly_started_at = DateTime.from_unix!(weekly_reset - 10_080 * 60) |> DateTime.to_iso8601()
    weekly_reset_at = DateTime.from_unix!(weekly_reset) |> DateTime.to_iso8601()

    {:ok, account} =
      Accounts.create_or_update("codex", "fallback", [email: "fallback@example.com"], settings)

    Accounts.record_rate_limits(
      account,
      %{
        "limitId" => "codex_bengalfox",
        "primary" => %{"usedPercent" => 12, "resetsAt" => session_reset, "windowDurationMins" => 300},
        "secondary" => %{"usedPercent" => 34.5, "resetsAt" => weekly_reset, "windowDurationMins" => 10_080}
      },
      settings
    )

    state_path = Path.join(account.account_dir, "state.json")

    state_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("rate_limit_periods", %{})
    |> Jason.encode!()
    |> then(&File.write!(state_path, &1))

    start_test_endpoint()

    conn = get(build_conn(), "/metrics")
    body = response(conn, 200)

    assert body =~
             ~s(symphony_account_usage_period_usage_percent{backend="codex",account_id="fallback",account_email="fallback@example.com",limit_id="codex_bengalfox",bucket="session",period="session",period_started_at="#{session_started_at}")

    assert body =~
             ~s(reset_at="#{weekly_reset_at}",period_status="active"} 34.50)

    assert body =~
             ~s(bucket="weekly",period="weekly",period_started_at="#{weekly_started_at}",reset_at="#{weekly_reset_at}",period_status="active"} 34.50)
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
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
        "symphony-elixir-metrics-#{suffix}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
