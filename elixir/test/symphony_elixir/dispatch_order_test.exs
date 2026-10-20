defmodule SymphonyElixir.DispatchOrderTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.Definition
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator

  # The AI Gym flow's shape: a back edge (test -> implement), a shortcut
  # (test -> review) and early exits to done.
  @flow %{
    "stages" => [
      %{"id" => "todo", "kind" => "queue"},
      %{"id" => "research", "kind" => "agent"},
      %{"id" => "plan", "kind" => "agent"},
      %{"id" => "implement", "kind" => "agent"},
      %{"id" => "test", "kind" => "agent"},
      %{"id" => "pr", "kind" => "agent"},
      %{"id" => "review", "kind" => "agent"},
      %{"id" => "blocked", "kind" => "human"},
      %{"id" => "done", "kind" => "done"},
      %{"id" => "orphan", "kind" => "agent"}
    ],
    "transitions" =>
      Enum.map(
        [
          {"todo", "research"},
          {"research", "plan"},
          {"research", "done"},
          {"plan", "implement"},
          {"plan", "research"},
          {"plan", "done"},
          {"implement", "test"},
          {"test", "implement"},
          {"test", "pr"},
          {"test", "review"},
          {"pr", "review"},
          {"review", "implement"},
          {"review", "done"},
          {"implement", "blocked"},
          {"blocked", "implement"}
        ],
        fn {from, to} -> %{"from" => from, "to" => to} end
      )
  }

  test "stage depth is the distance from the queue, unaffected by back edges" do
    depths = Definition.stage_depths(@flow)

    assert %{"todo" => 0, "research" => 1, "plan" => 2, "implement" => 3, "test" => 4, "pr" => 5, "review" => 5} =
             depths

    refute Map.has_key?(depths, "orphan")
    assert Definition.stage_depths(%{}) == %{}
  end

  defp issue(id, priority \\ 3), do: %Issue{id: id, identifier: id, priority: priority}

  defp staged(stage, id, priority \\ 3) do
    depths = Definition.stage_depths(@flow)
    kind = Enum.find(@flow["stages"], &(&1["id"] == stage))["kind"]
    {issue(id, priority), {kind, Map.get(depths, stage, 0)}}
  end

  test "later stages go first, whatever their Linear priority" do
    ordered =
      Orchestrator.order_for_dispatch([
        staged("todo", "T-1", 1),
        staged("research", "T-2", 1),
        staged("review", "T-3", 4),
        staged("implement", "T-4", 2),
        staged("test", "T-5", 3)
      ])

    assert Enum.map(ordered, fn {issue, _} -> issue.identifier end) == ["T-3", "T-5", "T-4", "T-2", "T-1"]
  end

  test "within a stage, Linear priority still decides" do
    ordered = Orchestrator.order_for_dispatch([staged("implement", "T-1", 3), staged("implement", "T-2", 1)])
    assert Enum.map(ordered, fn {issue, _} -> issue.identifier end) == ["T-2", "T-1"]
  end

  test "nothing leaves the queue while the pipeline holds as many issues as there are slots" do
    in_pipeline = for n <- 1..8, do: staged(Enum.at(~w(research plan implement test pr review), rem(n, 6)), "T-#{n}")
    queued = [staged("todo", "T-9"), staged("todo", "T-10")]

    assert Orchestrator.queue_allowance(in_pipeline ++ queued, 8) == 0
    assert Orchestrator.queue_allowance(in_pipeline ++ queued, 9) == 1
  end

  test "done and blocked issues free their slot" do
    pipeline = for n <- 1..6, do: staged("implement", "T-#{n}")
    finished = [staged("done", "T-7"), staged("blocked", "T-8")]

    assert Orchestrator.queue_allowance(pipeline ++ finished ++ [staged("todo", "T-9")], 8) == 2
  end
end
