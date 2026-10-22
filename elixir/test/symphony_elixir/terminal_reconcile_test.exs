defmodule SymphonyElixir.TerminalReconcileTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Factory.{Definition, Store}
  alias SymphonyElixir.UsageLedger

  setup do
    UsageLedger.reset()
    Store.reset()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      UsageLedger.reset()
      Store.reset()
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
    end)

    :ok
  end

  defp issue(state, labels, opts \\ []) do
    %Issue{
      id: "id-PAY-1",
      identifier: "PAY-1",
      title: "Fix the thing",
      state: state,
      state_type: Keyword.get(opts, :type),
      labels: labels,
      project_slug: "project"
    }
  end

  # A retry queued for the issue, as a failed run leaves it.
  defp with_retry(issue_id) do
    timer_ref = Process.send_after(self(), :retry_never_fires, 60_000)
    entry = %{attempt: 2, timer_ref: timer_ref, retry_token: make_ref(), identifier: "PAY-1", error: "boom"}
    %Orchestrator.State{claimed: MapSet.new([issue_id]), retry_attempts: %{issue_id => entry}}
  end

  defp moves(identifier), do: UsageLedger.issue_history(identifier).moves
  defp node_of(identifier), do: Enum.find_value(UsageLedger.snapshot().flow.issues, &(&1.issue == identifier && &1.node))

  test "an issue closed in Linear while blocked moves to done, as a move made outside the factory" do
    UsageLedger.observe_issue(issue("In Progress", ["factory/implement"]))
    UsageLedger.observe_issue(issue("In Progress", ["factory/blocked"]))
    assert node_of("PAY-1") == "blocked"
    assert UsageLedger.unsettled_issue_ids() == ["id-PAY-1"]

    # Closed in Linear (a PR merge integration), still carrying its blocked and approval labels.
    closed = issue("Done", ["factory/blocked", "needs-approval", "bug"], type: "completed")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [closed])

    state =
      capture_log_result(fn -> Orchestrator.apply_tracked_issues_for_test(with_retry("id-PAY-1"), {:ok, [closed]}) end, "reached done outside the factory")

    assert node_of("PAY-1") == "done"
    assert [["implement", "blocked", _], ["blocked", "done", _, "external"]] = moves("PAY-1")

    # The parked markers go: stage and approval labels, the queued retry and its claim.
    assert_receive {:memory_tracker_stage_update, "id-PAY-1", "Done", nil}, 1_000
    assert [%Issue{labels: ["bug"]}] = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    assert state.retry_attempts == %{}
    refute MapSet.member?(state.claimed, "id-PAY-1")
    refute_received :retry_never_fires

    # Nothing dispatches it, and the next polls don't read it again.
    refute Orchestrator.should_dispatch_issue_for_test(closed, state)
    assert UsageLedger.unsettled_issue_ids() == []
  end

  test "an issue in review reaching a completed state the flow has no stage for still lands in done" do
    UsageLedger.observe_issue(issue("In Review", []))
    assert node_of("PAY-1") == "review"

    shipped = issue("Shipped", [], type: "completed")
    state = Orchestrator.apply_tracked_issues_for_test(%Orchestrator.State{}, {:ok, [shipped]})

    assert node_of("PAY-1") == "done"
    assert [["review", "done", _, "external"]] = moves("PAY-1")
    # No stale labels: nothing to write back.
    refute_receive {:memory_tracker_stage_update, _, _, _}, 50
    refute Orchestrator.should_dispatch_issue_for_test(shipped, state)
  end

  test "reconciling a closed issue again changes nothing" do
    UsageLedger.observe_issue(issue("In Progress", ["factory/blocked"]))
    closed = issue("Done", [], type: "completed")

    state = Orchestrator.apply_tracked_issues_for_test(%Orchestrator.State{}, {:ok, [closed]})
    before = moves("PAY-1")
    state = Orchestrator.apply_tracked_issues_for_test(state, {:ok, [closed]})
    _state = Orchestrator.apply_tracked_issues_for_test(state, {:ok, [closed]})

    assert moves("PAY-1") == before
    assert [["blocked", "done", _, "external"]] = before
    assert UsageLedger.snapshot().flow.edges |> Enum.map(&{&1.from, &1.to, &1.count}) == [{"blocked", "done", 1}]
    refute_receive {:memory_tracker_stage_update, _, _, _}, 50
  end

  test "a canceled issue goes to the flow's stage for that state, else out of the flow" do
    UsageLedger.observe_issue(issue("In Progress", ["factory/blocked"]))
    Orchestrator.apply_tracked_issues_for_test(%Orchestrator.State{}, {:ok, [issue("Duplicate", ["factory/blocked"], type: "canceled")]})

    assert node_of("PAY-1") == "canceled"
    assert [["blocked", "canceled", _, "external"]] = moves("PAY-1")
    assert_receive {:memory_tracker_stage_update, "id-PAY-1", "Duplicate", nil}, 1_000
    assert UsageLedger.unsettled_issue_ids() == []

    # A project flow with a stage of its own for canceled work.
    template = Definition.default_template()
    dropped = %{"id" => "dropped", "name" => "Dropped", "kind" => "done", "linear_state" => "Canceled", "position" => %{"x" => 0, "y" => 0}}
    {:ok, _} = Store.put("project:project", %{template | "stages" => template["stages"] ++ [dropped]}, 0, "mia")

    UsageLedger.reset()
    UsageLedger.observe_issue(%{issue("In Review", []) | identifier: "PAY-2", id: "id-PAY-2"})
    canceled = %{issue("Canceled", [], type: "canceled") | identifier: "PAY-2", id: "id-PAY-2"}
    Orchestrator.apply_tracked_issues_for_test(%Orchestrator.State{}, {:ok, [canceled]})

    assert node_of("PAY-2") == "dropped"
    assert [["review", "dropped", _, "external"]] = moves("PAY-2")
  end

  test "only issues in an open stage are re-read, at most once a minute unless a refresh asks" do
    UsageLedger.observe_issue(issue("In Progress", ["factory/blocked"]))
    UsageLedger.observe_issue(%{issue("Done", []) | identifier: "PAY-2", id: "id-PAY-2"})
    UsageLedger.observe_issue(%{issue("Backlog", []) | identifier: "PAY-3", id: "id-PAY-3"})
    UsageLedger.observe_issue(%{issue("In Review", []) | identifier: "PAY-4", id: "id-PAY-4"})

    {ids, state} = Orchestrator.tracked_issue_ids_for_test(%Orchestrator.State{})
    assert Enum.sort(ids) == ["id-PAY-1", "id-PAY-4"]
    assert {[], ^state} = Orchestrator.tracked_issue_ids_for_test(state)
    assert {[_, _], _state} = Orchestrator.tracked_issue_ids_for_test(%{state | tracked_refreshed_at_ms: nil})

    # Issues the candidate fetch or the running refresh already read are skipped,
    # and nothing is read while Linear is failing.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("Done", [], type: "completed"), %{issue("In Review", []) | id: "id-PAY-4"}])
    assert {:ok, [%Issue{id: "id-PAY-1"}]} = Orchestrator.fetch_tracked_states_for_test(ids, [], {:ok, [%Issue{id: "id-PAY-4"}]})
    assert {:ok, []} = Orchestrator.fetch_tracked_states_for_test(ids, ["id-PAY-1", "id-PAY-4"], {:ok, []})
    assert {:ok, []} = Orchestrator.fetch_tracked_states_for_test(ids, [], {:error, :linear_down})
  end

  test "a running issue that closed is left to the running reconcile" do
    UsageLedger.observe_issue(issue("In Progress", ["factory/blocked"]))
    state = %{with_retry("id-PAY-1") | running: %{"id-PAY-1" => %{identifier: "PAY-1"}}}

    assert ^state = Orchestrator.apply_tracked_issues_for_test(state, {:ok, [issue("Done", ["factory/blocked"], type: "completed")]})
    assert node_of("PAY-1") == "done"
    refute_receive {:memory_tracker_stage_update, _, _, _}, 50
  end

  defp capture_log_result(fun, expected) do
    parent = self()
    log = capture_log(fn -> send(parent, {:result, fun.()}) end)
    assert log =~ expected
    assert_received {:result, result}
    result
  end
end
