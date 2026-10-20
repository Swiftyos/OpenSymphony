defmodule SymphonyElixir.RequireLabelTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.IssueStage
  alias SymphonyElixir.Linear.Issue

  defp settings(tracker) do
    {:ok, settings} = Schema.parse(%{"tracker" => Map.merge(%{"kind" => "memory"}, tracker)})
    settings
  end

  defp issue(labels), do: %Issue{id: "1", identifier: "PAY-1", state: "In Progress", labels: labels}

  test "without require_label every issue is opted in" do
    settings = settings(%{})
    assert settings.tracker.require_label == nil
    assert IssueStage.opted_in?(issue([]), settings)
    refute IssueStage.paused?(issue([]), settings)
  end

  test "with require_label only issues carrying it are dispatched" do
    settings = settings(%{"require_label" => "  Auto-Build "})
    assert settings.tracker.require_label == "Auto-Build"

    refute IssueStage.opted_in?(issue([]), settings)
    assert IssueStage.paused?(issue(["factory/implement"]), settings)
    refute IssueStage.active?(issue([]), settings)

    assert IssueStage.opted_in?(issue(["auto-build"]), settings)
    assert IssueStage.opted_in?(issue(["ai/AUTO-BUILD"]), settings)
    refute IssueStage.opted_in?(issue(["not-auto-build"]), settings)
    refute IssueStage.paused?(issue(["auto-build", "factory/implement"]), settings)
    assert IssueStage.active?(issue(["auto-build"]), settings)

    # Opting in doesn't override a stage that holds issues still.
    assert IssueStage.paused?(issue(["auto-build", "factory/blocked"]), settings)
  end

  test "a blank require_label means no gate" do
    assert settings(%{"require_label" => "  "}).tracker.require_label == nil
  end
end
