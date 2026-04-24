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
    assert weekly_panel["targets"] |> Enum.any?(&String.contains?(&1["expr"], "symphony_account_usage_period_usage_percent"))
  end
end
