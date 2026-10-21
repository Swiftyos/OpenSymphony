defmodule SymphonyElixir.RequireLabelDispatchTest do
  use SymphonyElixir.TestSupport

  defp issue(id, state, labels) do
    %Issue{id: "id-" <> id, identifier: id, title: "Task " <> id, state: state, labels: labels, project_slug: "project"}
  end

  defp state(running \\ %{}) do
    %Orchestrator.State{
      max_concurrent_agents: 5,
      running: running,
      claimed: MapSet.new(),
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end

  test "issues in agent stages that can never be dispatched don't hold a queue slot" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_require_label: "auto-build")

    working = for n <- 1..2, do: issue("MT-#{n}", "In Progress", ["auto-build"])
    # People's own issues in a watched project, without the opt-in label.
    not_opted_in = for n <- 3..5, do: issue("MT-#{n}", "In Progress", [])
    awaiting_approval = issue("MT-6", "In Progress", ["auto-build", "needs-approval"])
    queued = issue("MT-7", "Todo", ["auto-build"])

    assert Orchestrator.queue_allowance_for_test(working ++ not_opted_in ++ [awaiting_approval, queued], state()) == 3
  end

  test "a running issue holds its slot even when it couldn't be dispatched again" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_require_label: "auto-build")

    # The label was removed while its agent runs: the agent still uses a slot.
    unlabelled = issue("MT-1", "In Progress", [])
    running = %{unlabelled.id => %{pid: self(), ref: nil, identifier: "MT-1", issue: unlabelled}}

    assert Orchestrator.queue_allowance_for_test([unlabelled, issue("MT-2", "Todo", ["auto-build"])], state(running)) == 4
  end

  test "removing the opt-in label stops the running agent on the next poll" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_require_label: "auto-build")

    agent = spawn(fn -> receive do: (:stop -> :ok) end)
    labelled = issue("MT-1", "In Progress", ["auto-build"])
    running = %{labelled.id => %{pid: agent, ref: nil, identifier: "MT-1", issue: labelled, started_at: DateTime.utc_now()}}

    log =
      capture_log(fn ->
        updated = Orchestrator.reconcile_issue_states_for_test([issue("MT-1", "In Progress", [])], state(running))
        refute Map.has_key?(updated.running, labelled.id)
      end)

    refute Process.alive?(agent)
    assert log =~ "lost the auto-build label"
  end
end
