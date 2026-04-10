defmodule SymphonyElixir.AgentRouteTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRoute

  test "unlabeled issue uses configured fallback backend and effort" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "claude",
      default_effort: "medium"
    )

    route = AgentRoute.resolve(issue_fixture([]))

    assert route.backend == "claude"
    assert route.effort == "medium"
    assert route.warnings == []
  end

  test "backend labels override the configured fallback backend" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "codex")

    assert AgentRoute.resolve(issue_fixture(["codex"])).backend == "codex"
    assert AgentRoute.resolve(issue_fixture(["claude"])).backend == "claude"
    assert AgentRoute.resolve(issue_fixture(["opencode"])).backend == "opencode"
  end

  test "effort labels override the configured fallback effort" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "codex",
      default_effort: "low"
    )

    assert AgentRoute.resolve(issue_fixture(["effort/high"])).effort == "high"
    assert AgentRoute.resolve(issue_fixture(["EFFORT/MAX"])).effort == "max"
  end

  test "conflicting backend labels warn and fall back to the configured backend" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "claude")

    route = AgentRoute.resolve(issue_fixture(["codex", "claude"]))

    assert route.backend == "claude"
    assert route.effort == nil

    assert route.warnings == [
             "multiple backend labels (codex, claude) found; falling back to default backend claude"
           ]
  end

  test "conflicting effort labels warn and fall back to configured effort" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "codex",
      default_effort: "medium"
    )

    route = AgentRoute.resolve(issue_fixture(["effort/low", "effort/max"]))

    assert route.backend == "codex"
    assert route.effort == "medium"

    assert route.warnings == [
             "multiple effort labels (low, max) found; falling back to default effort medium"
           ]
  end

  defp issue_fixture(labels) do
    %Issue{
      id: "issue-route",
      identifier: "MT-ROUTE",
      title: "Route test",
      description: "Route from labels",
      state: "Todo",
      url: "https://example.org/issues/MT-ROUTE",
      labels: labels
    }
  end
end
