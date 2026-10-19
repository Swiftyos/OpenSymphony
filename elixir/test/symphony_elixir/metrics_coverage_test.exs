defmodule SymphonyElixir.MetricsCoverageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Accounts
  alias SymphonyElixirWeb.PrometheusMetrics

  test "render returns only metric headers when accounts are disabled or unavailable" do
    disabled = PrometheusMetrics.render(%{})
    assert disabled =~ "# HELP symphony_account_state_info Account identity and current state information."
    refute disabled =~ "symphony_account_state_info{"

    broken = PrometheusMetrics.render(%{accounts: %{enabled: true, store_root: 123}})
    assert broken == disabled
  end

  test "render/0 reads the configured settings" do
    assert PrometheusMetrics.render() == PrometheusMetrics.render(%{})
  end

  test "render emits rate-limit and token samples for well-formed account state" do
    root = temp_root!("standard")
    settings = %{accounts: %{enabled: true, store_root: root}}
    {:ok, account} = Accounts.create_or_update("codex", "std", [email: "std@example.com"], settings)

    update_state!(account, %{
      "latest_rate_limits" => %{
        "limit_id" => "std-limit",
        "session" => %{
          "limit" => 10,
          "remaining" => 4,
          "reset_at" => "2030-01-01T01:00:00Z",
          "windowDurationMins" => 30,
          "usage_percent" => 61
        },
        "weekly" => %{"reset_at" => "2030-01-08T00:00:00Z", "windowDurationMins" => 60, "usage_percent" => "12.5"}
      },
      "rate_limit_periods" => %{
        "session" => %{
          "started_at" => "2030-01-01T00:00:00Z",
          "reset_at" => "2030-01-01T01:00:00Z",
          "input_tokens" => 3
        }
      }
    })

    body = PrometheusMetrics.render(settings)
    labels = ~s(backend="codex",account_id="std",account_email="std@example.com",limit_id="std-limit",bucket="session")

    assert body =~ ~s(symphony_account_rate_limit_usage_percent{#{labels}} 61.00)
    assert body =~ ~s(symphony_account_rate_limit_used{#{labels}} 6)

    period =
      labels <>
        ~s(,period="session",period_started_at="2030-01-01T00:00:00Z",reset_at="2030-01-01T01:00:00Z",) <>
        ~s(period_status="active")

    assert body =~ ~s(symphony_account_usage_period_tokens{#{period},token_type="input"} 3)
    assert body =~ ~s(symphony_account_usage_period_usage_percent{#{period}} 61.00)

    assert body =~
             ~s(bucket="weekly",period="weekly",period_started_at="2030-01-07T23:00:00Z",) <>
               ~s(reset_at="2030-01-08T00:00:00Z",period_status="active"} 12.50)
  end

  test "render normalizes unusual rate-limit, period, and csv shapes" do
    root = temp_root!("shapes")
    settings = %{accounts: %{enabled: true, store_root: root}}

    {:ok, alpha} = Accounts.create_or_update("claude", "alpha", [], settings)
    {:ok, beta} = Accounts.create_or_update("codex", "beta", [email: "beta@example.com"], settings)
    {:ok, gamma} = Accounts.create_or_update("codex", "gamma", [email: "gamma@example.com"], settings)

    update_state!(alpha, %{
      "latest_rate_limits" => %{
        "limitName" => "lim-a",
        "session" => %{
          "limit" => 100.0,
          "remaining" => " 40 ",
          "resetsAt" => "1900000000",
          "window_minutes" => 60,
          "usage_percent" => "abc"
        },
        "weekly" => %{"limit" => "x", "remaining" => 5, "reset_after_seconds" => 3600}
      },
      "rate_limit_periods" => %{
        "session" => %{"started_at" => "garbage", "reset_at" => 99_999_999_999_999_999_999},
        "weekly" => "not-a-map",
        "monthly" => %{"limit" => 5, "remaining" => 2, "started_at" => 1.5},
        "daily" => %{"used" => 7}
      }
    })

    update_state!(beta, %{"latest_rate_limits" => nil, "rate_limit_periods" => %{}})
    File.write!(Path.join(beta.account_dir, "usage_periods.csv"), "\n\n")

    update_state!(gamma, %{
      "latest_rate_limits" => %{
        "session" => %{"reset_in_seconds" => 0, "remaining" => 1},
        "weekly" => %{"limit" => 3}
      },
      "rate_limit_periods" => %{}
    })

    File.write!(
      Path.join(gamma.account_dir, "usage_periods.csv"),
      "limit_id,bucket,period,limit,used\n" <>
        ~s("""quoted"" id","a,b",weekly,10,4\n) <>
        "short,row\n"
    )

    body = PrometheusMetrics.render(settings)

    # account without email renders an empty email label
    assert body =~
             ~s(symphony_account_state_info{backend="claude",account_id="alpha",account_email="",state="unknown")

    alpha_session = ~s(backend="claude",account_id="alpha",account_email="",limit_id="lim-a",bucket="session")
    assert body =~ ~s(symphony_account_rate_limit_limit{#{alpha_session}} 100)
    assert body =~ ~s(symphony_account_rate_limit_remaining{#{alpha_session}} 40)
    assert body =~ ~s(symphony_account_rate_limit_used{#{alpha_session}} 60)
    assert body =~ ~s(symphony_account_rate_limit_usage_percent{#{alpha_session}} 60.00)
    assert body =~ ~s(symphony_account_rate_limit_reset_timestamp_seconds{#{alpha_session}} 1900000000)

    alpha_weekly = ~s(backend="claude",account_id="alpha",account_email="",limit_id="lim-a",bucket="weekly")
    refute body =~ ~s(symphony_account_rate_limit_limit{#{alpha_weekly}})
    assert body =~ ~s(symphony_account_rate_limit_remaining{#{alpha_weekly}} 5)
    assert body =~ ~s(symphony_account_rate_limit_reset_timestamp_seconds{#{alpha_weekly}} )

    session_reset = DateTime.from_unix!(1_900_000_000)
    session_started = session_reset |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

    assert body =~
             ~s(#{alpha_session},period="session",period_started_at="#{session_started}",) <>
               ~s(reset_at="#{DateTime.to_iso8601(session_reset)}",period_status="active"} 60.00)

    # the non-map persisted weekly period is replaced by a fallback row from the current bucket
    assert body =~ ~s(#{alpha_weekly},period="weekly",period_started_at="",reset_at=")

    # monthly period with no matching current bucket
    monthly =
      ~s(backend="claude",account_id="alpha",account_email="",limit_id="",bucket="monthly",) <>
        ~s(period="monthly",period_started_at="",reset_at="",period_status="active")

    assert body =~ ~s(symphony_account_usage_period_used{#{monthly}} 3)
    assert body =~ ~s(symphony_account_usage_period_usage_percent{#{monthly}} 60.00)

    assert body =~
             ~s(symphony_account_usage_period_used{backend="claude",account_id="alpha",account_email="",) <>
               ~s(limit_id="",bucket="daily",period="daily",period_started_at="",reset_at="",period_status="active"} 7)

    refute body =~ ~s(account_id="beta",account_email="beta@example.com",limit_id=)

    gamma_session = ~s(backend="codex",account_id="gamma",account_email="gamma@example.com",limit_id="",bucket="session")
    assert body =~ ~s(symphony_account_rate_limit_remaining{#{gamma_session}} 1)
    refute body =~ ~s(symphony_account_rate_limit_reset_timestamp_seconds{#{gamma_session}})

    gamma_weekly = ~s(backend="codex",account_id="gamma",account_email="gamma@example.com",limit_id="",bucket="weekly")
    assert body =~ ~s(symphony_account_rate_limit_limit{#{gamma_weekly}} 3)
    refute body =~ ~s(symphony_account_rate_limit_reset_timestamp_seconds{#{gamma_weekly}})

    closed =
      ~s(backend="codex",account_id="gamma",account_email="gamma@example.com",limit_id="quoted\\" id",) <>
        ~s(bucket="a,b",period="weekly",period_started_at="",reset_at="",period_status="closed")

    assert body =~ ~s(symphony_account_usage_period_limit{#{closed}} 10)
    assert body =~ ~s(symphony_account_usage_period_used{#{closed}} 4)
    assert body =~ ~s(symphony_account_usage_period_usage_percent{#{closed}} 40.00)
    refute body =~ "short"
  end

  defp update_state!(account, updates) do
    path = Path.join(account.account_dir, "state.json")

    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.merge(updates)
    |> Jason.encode!()
    |> then(&File.write!(path, &1))
  end

  defp temp_root!(suffix) do
    root = Path.join(System.tmp_dir!(), "symphony-metrics-cov-#{suffix}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
