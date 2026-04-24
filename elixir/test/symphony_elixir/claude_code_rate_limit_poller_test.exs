defmodule SymphonyElixir.ClaudeCode.RateLimitPollerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Accounts
  alias SymphonyElixir.ClaudeCode.RateLimitPoller

  test "poll_now records rate limits for every probeable claude account" do
    store_root = temp_accounts_root!("poller-record")
    enable_probe_in_workflow!(store_root)

    {:ok, _account_a} = Accounts.create_or_update("claude", "alpha", [email: "alpha@example.com"])
    {:ok, _account_b} = Accounts.create_or_update("claude", "beta", [email: "beta@example.com"])
    {:ok, paused} = Accounts.create_or_update("claude", "paused", [])
    {:ok, _} = Accounts.pause("claude", paused.id, [reason: "hold"])

    parent = self()

    probe_fun = fn account ->
      send(parent, {:probed, account.id})

      {:ok,
       %{
         "limit_id" => "anthropic_oauth",
         "session" => %{
           "period" => "session",
           "status" => "allowed",
           "limit" => 100,
           "remaining" => 42,
           "usage_percent" => 58.0,
           "reset_at" => "2030-01-01T00:00:00Z"
         }
       }}
    end

    pid =
      start_supervised!({RateLimitPoller,
       name: :"rate_limit_poller_#{System.unique_integer([:positive])}",
       probe_fun: probe_fun})

    RateLimitPoller.poll_now(pid)
    ensure_poll_completed(pid)

    assert_received {:probed, "alpha"}
    assert_received {:probed, "beta"}
    refute_received {:probed, "paused"}

    {:ok, alpha} = Accounts.get("claude", "alpha")
    assert alpha.latest_rate_limits["session"]["remaining"] == 42
    assert alpha.state == "healthy"
  end

  test "poll_now is a no-op when accounts tracking is disabled" do
    write_workflow_file!(Workflow.workflow_file_path(), accounts_enabled: false)

    probe_fun = fn _account -> flunk("probe should not run when accounts disabled") end

    pid =
      start_supervised!({RateLimitPoller,
       name: :"rate_limit_poller_#{System.unique_integer([:positive])}",
       probe_fun: probe_fun})

    RateLimitPoller.poll_now(pid)
    ensure_poll_completed(pid)
  end

  defp enable_probe_in_workflow!(store_root) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      accounts_enabled: true,
      accounts_store_root: store_root,
      accounts_claude_rate_limit_probe_interval_ms: 60_000
    )
  end

  defp temp_accounts_root!(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-poller-#{suffix}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp ensure_poll_completed(pid) do
    :sys.get_state(pid)
    :ok
  end
end
