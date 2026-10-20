defmodule SymphonyElixir.IssueReportTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Factory.Store
  alias SymphonyElixir.{IssueReport, StageResult, UsageLedger}
  alias SymphonyElixir.Linear.Issue

  @flow %{
    "stages" =>
      Enum.with_index(~w(todo implement test review done), fn id, i ->
        %{"id" => id, "name" => String.capitalize(id), "kind" => if(id == "done", do: "done", else: "agent"), "position" => %{"x" => i * 100}}
      end)
  }

  setup do
    UsageLedger.reset()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      UsageLedger.reset()
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    :ok
  end

  defp moves(path), do: path |> Enum.chunk_every(2, 1, :discard) |> Enum.with_index(fn [a, b], i -> [a, b, i] end)

  test "review is the outer loop; test failures are counted per review round" do
    # Round 1: test fails twice, then review sends it back. Round 2: review sends it back
    # again. Round 3: test fails once, then it passes review.
    path = ~w(todo implement test implement test implement test review implement test review implement test implement test review done)
    rounds = IssueReport.rounds(moves(path), @flow)

    assert rounds.outer == "Review"
    assert rounds.rounds == 3
    assert rounds.knockbacks == %{"Test" => 3, "Review" => 2}
    assert rounds.inner == [%{"Test" => 2}, %{}, %{"Test" => 1}]
  end

  test "an issue that went straight through, and one only tests sent back" do
    assert %{knockbacks: %{}, rounds: 1, outer: nil} = IssueReport.rounds(moves(~w(todo implement test review done)), @flow)
    assert %{outer: "Test", rounds: 2} = IssueReport.rounds(moves(~w(implement test implement test)), @flow)
    # Stages a flow no longer has still count, after the known ones.
    assert %{knockbacks: %{"gone" => 1}} = IssueReport.rounds([["gone", "implement", 0]], @flow)
  end

  test "the report breaks usage down by stage with totals, and posts when an issue is done" do
    issue = %Issue{id: "id-PAY-1", identifier: "PAY-1", title: "T", state: "In Progress", labels: ["factory/implement"]}
    for state <- ["Todo", "In Progress"], do: UsageLedger.observe_issue(%{issue | state: state, labels: ["factory/implement"]})

    codex = %{input_tokens: 2_000_000, cached_input_tokens: 1_500_000, output_tokens: 3_000, cost_micros: 120_000}
    UsageLedger.record_tokens(%{issue: issue, backend: "codex"}, codex)
    in_review = %{issue | state: "In Review", labels: []}
    claude = %{input_tokens: 900, output_tokens: 50, cost_micros: 40_000}
    UsageLedger.record_tokens(%{issue: in_review, backend: "claude"}, claude)

    report = IssueReport.markdown("PAY-1", Store.get("PAY"))
    assert report =~ "## Factory report"
    assert report =~ "| Implement | 2.0M | 1.5M | 3k | $0.12 |"
    assert report =~ "| In Review | 900 | 0 | 50 | $0.04 |"
    assert report =~ "| **Total** | **2.0M** | **1.5M** | **3k** | **$0.16** |"
    assert report =~ "Harnesses: claude (default), codex (default)."
    assert report =~ "**Rounds:** none"
    refute report =~ "≈"

    # Usage recorded before pricing (no cost) and with no price configured shows as estimated.
    UsageLedger.record_tokens(%{issue: %{issue | state: "Done"}, backend: "opencode"}, %{input_tokens: 10, output_tokens: 10})
    assert IssueReport.markdown("PAY-1", Store.get("PAY")) =~ "≈ $0.16"

    done = %{"kind" => "done", "linear_state" => "Done"}
    assert StageResult.finished(issue, done, Store.get("PAY")) == :ok
    assert_receive {:memory_tracker_comment, "id-PAY-1", "## Factory report" <> _}
    assert StageResult.finished(issue, %{"kind" => "agent"}, %{}) == :ok
  end

  test "the report lists rounds and test failures per round, and estimates unpriced usage" do
    # Recorded while no price was configured, so priced (approximately) when the report is made.
    unpriced = %Issue{id: "id-PAY-7", identifier: "PAY-7", title: "T", state: "Somewhere"}
    UsageLedger.record_tokens(%{issue: unpriced, backend: "codex"}, %{input_tokens: 1_000_000, output_tokens: 0})

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
    pricing:
      codex:
        input_per_mtok: 1
    ---
    Prompt.
    """)

    SymphonyElixir.WorkflowStore.force_reload()

    path = ~w(Todo implement test implement test review implement test review done)
    states = %{"Todo" => {"Todo", []}, "done" => {"Done", []}, "review" => {"In Review", []}}
    flow = Store.get("PAY")
    base = %Issue{id: "id-PAY-7", identifier: "PAY-7", title: "T"}

    # The default flow has no test stage, so record PAY-7's moves through this test's own flow.
    for step <- path do
      {state, labels} = Map.get(states, step, {"In Progress", ["factory/" <> step]})
      UsageLedger.observe_issue(%{base | state: state, labels: labels})
    end

    report = IssueReport.markdown("PAY-7", flow)
    assert report =~ "| Before stages were tracked | 1.0M | 0 | 0 | ≈ $1.00 |"
    assert report =~ "Costs marked ≈"

    rounds = IssueReport.rounds(moves(~w(implement test implement test review implement test review done)), @flow)
    assert rounds.outer == "Review"
    assert IssueReport.rounds_text(rounds) =~ "**Rounds:** 2 rounds of Review (it sent the work back 1×)."
    assert IssueReport.rounds_text(rounds) =~ "- **Test** sent it back 1× (per Review round: 1 · 0)"
    assert IssueReport.rounds_text(IssueReport.rounds([["test", "implement", 0]], @flow)) =~ "2 rounds of Test"
  end

  test "an issue with no usage says so" do
    assert IssueReport.markdown("PAY-404", @flow) =~ "No agent usage was recorded for this issue."
  end
end
