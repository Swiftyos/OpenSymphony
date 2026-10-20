defmodule SymphonyElixir.StageResultTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Factory.{Definition, StagePrompt, Store}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.StageResult

  setup do
    Store.reset()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    workspace = Path.join(System.tmp_dir!(), "stage-result-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, ".git/info"))

    on_exit(fn ->
      Store.reset()
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      File.rm_rf!(workspace)
    end)

    issue = %Issue{id: "id-PAY-1", identifier: "PAY-1", state: "In Progress", labels: ["factory/implement"]}
    %{workspace: workspace, issue: issue}
  end

  defp write_result(workspace, result) do
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(StageResult.path(workspace), if(is_binary(result), do: result, else: Jason.encode!(result)))
  end

  defp kept(workspace), do: workspace |> Path.join(".symphony") |> File.ls!() |> Enum.sort()

  test "no result file means nothing to do", %{workspace: workspace, issue: issue} do
    assert StageResult.process(issue, workspace) == :none
  end

  test "an allowed move with a summary posts the comment and moves the issue", %{workspace: workspace, issue: issue} do
    write_result(workspace, %{"move" => "review", "summary" => "Opened PR #4."})

    assert {:moved, %{"id" => "review"}} = StageResult.process(issue, workspace)
    assert_receive {:memory_tracker_comment, "id-PAY-1", body}
    assert body =~ "## Implement\n\nOpened PR #4."
    assert body =~ "_Moved to In Review by Symphony._"
    assert_receive {:memory_tracker_stage_update, "id-PAY-1", "In Review", nil}
    assert [<<"accepted-", _::binary>>] = kept(workspace)
  end

  test "a move out of a stage that needs approval is held", %{workspace: workspace, issue: issue} do
    template = Definition.default_template()
    stages = Enum.map(template["stages"], &if(&1["id"] == "implement", do: Map.put(&1, "approval", true), else: &1))
    {:ok, _} = Store.put("PAY", %{template | "stages" => stages}, 0, "mia")
    write_result(workspace, %{"move" => "review", "summary" => "Done."})

    assert {:moved, _} = StageResult.process(issue, workspace)
    assert_receive {:memory_tracker_comment, _, body}
    assert body =~ "waiting for a person to approve"
  end

  test "bad results are set aside with a reason for the agent", %{workspace: workspace, issue: issue} do
    write_result(workspace, "not json")
    assert {:rejected, message} = StageResult.process(issue, workspace)
    assert message =~ ~s(must be JSON like)

    write_result(workspace, %{"move" => "review", "summary" => "  "})
    assert {:rejected, message} = StageResult.process(issue, workspace)
    assert message =~ "summary"

    write_result(workspace, %{"move" => "merge", "summary" => "x"})
    assert {:rejected, message} = StageResult.process(issue, workspace)
    assert message =~ ~s("merge" isn't a move you can make from Implement. Pick one of: review, blocked.)

    write_result(workspace, %{"move" => "review", "summary" => "x"})
    assert {:rejected, message} = StageResult.process(%{issue | state: "Nowhere"}, workspace)
    assert message =~ "isn't in a stage of its flow"

    assert length(kept(workspace)) == 4
    refute File.exists?(StageResult.path(workspace))
  end

  test "the stage's checks must pass", %{workspace: workspace, issue: issue} do
    template = Definition.default_template()
    stages = Enum.map(template["stages"], &if(&1["id"] == "implement", do: Map.put(&1, "checks", ["true", "echo boom; exit 3"]), else: &1))
    {:ok, _} = Store.put("PAY", %{template | "stages" => stages}, 0, "mia")

    write_result(workspace, %{"move" => "review", "summary" => "x"})
    assert {:rejected, message} = StageResult.process(issue, workspace)
    assert message =~ "`echo boom; exit 3` exited 3:\nboom"
    refute message =~ "`true`"

    write_result(workspace, %{"move" => "review", "summary" => "x"})
    assert {:moved, _} = StageResult.process(issue, workspace, check_runner: fn _command, _workspace -> {0, ""} end)
    write_result(workspace, %{"move" => "review", "summary" => "x"})
    assert {:rejected, message} = StageResult.process(issue, workspace, check_timeout_ms: 1)
    assert message =~ "timed out after 0 seconds"

    # The prompt lists the checks, and person-moved connections as not the agent's.
    prompt = StagePrompt.render(issue)
    assert prompt =~ "Symphony runs these checks in your workspace; all must pass:\n- `true`\n- `echo boom; exit 3`"
    review = StagePrompt.render(%{issue | state: "In Review", labels: []})
    assert review =~ "- **Merge** (a person moves it, not you): The reviewer approves the PR."
  end

  test "an unreadable result file is reported", %{workspace: workspace, issue: issue} do
    File.mkdir_p!(StageResult.path(workspace))
    assert {:rejected, message} = StageResult.process(issue, workspace)
    assert message =~ "couldn't read"
  end

  test ".symphony is kept out of git once", %{workspace: workspace} do
    assert StageResult.exclude_from_git(workspace) == :ok
    assert StageResult.exclude_from_git(workspace) == :ok
    assert File.read!(Path.join(workspace, ".git/info/exclude")) == "\n/.symphony/\n"
    assert StageResult.exclude_from_git(Path.join(workspace, "no-repo")) == :ok
  end

  test "a failed Linear update asks the agent to retry", %{workspace: workspace, issue: issue} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", tracker_api_token: "k")
    Application.put_env(:symphony_elixir, :linear_client_module, __MODULE__.DownLinear)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_module) end)

    write_result(workspace, %{"move" => "review", "summary" => "x"})
    assert {:rejected, message} = StageResult.process(issue, workspace)
    assert message =~ "couldn't update Linear"
  end

  defmodule DownLinear do
    def graphql(_query, _variables, _opts \\ []), do: {:error, :down}
  end
end
