defmodule SymphonyElixir.GrafanaDashboardTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @dashboard_path Path.join(@repo_root, "observability/grafana/dashboards/account-usage.json")

  test "account usage dashboard json is valid" do
    dashboard =
      @dashboard_path
      |> File.read!()
      |> Jason.decode!()

    assert dashboard["uid"] == "account-usage"
    assert dashboard["title"] == "Account Usage"

    panel_titles =
      dashboard["panels"]
      |> Enum.map(& &1["title"])

    assert "Per-Account Token Usage" in panel_titles
    assert "Current Limit Used" in panel_titles
    assert "Weekly Billing-Cycle Usage" in panel_titles

    token_panel = Enum.find(dashboard["panels"], &(&1["title"] == "Per-Account Token Usage"))
    weekly_panel = Enum.find(dashboard["panels"], &(&1["title"] == "Weekly Billing-Cycle Usage"))

    assert token_panel["targets"] |> Enum.any?(&String.contains?(&1["expr"], "event.name:codex.sse_event"))
    assert token_panel["targets"] |> Enum.any?(&String.contains?(&1["expr"], "symphony.backend:\"claude\""))

    claude_targets =
      token_panel["targets"]
      |> Enum.filter(&String.contains?(&1["expr"], "symphony.backend:\"claude\""))

    assert claude_targets != []

    for target <- claude_targets do
      assert String.contains?(target["expr"], "_msg:=api_request"),
             "claude token query should match on _msg:=api_request (not event.name:api_request)"

      assert String.contains?(target["expr"], "symphony.account.id:~\"${account_id:regex}\""),
             "claude token query should filter by symphony.account.id, not user.account_id"

      refute String.contains?(target["expr"], "user.account_id"),
             "claude token query should not reference user.account_id — it's Anthropic's OAuth id, not Symphony's account_id"
    end
    assert weekly_panel["targets"] |> Enum.any?(&String.contains?(&1["expr"], "symphony_account_usage_period_usage_percent"))
  end
end
