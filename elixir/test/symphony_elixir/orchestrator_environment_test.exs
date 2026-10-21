defmodule SymphonyElixir.OrchestratorEnvironmentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Transcript

  setup do
    Transcript.reset()
    on_exit(&Transcript.reset/0)

    previous = Application.get_env(:symphony_elixir, :startup_mode)
    Application.put_env(:symphony_elixir, :startup_mode, :legacy)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :startup_mode, previous),
        else: Application.delete_env(:symphony_elixir, :startup_mode)
    end)

    :ok
  end

  # A catalog without `default` and no route/team/stage choice rejects every issue.
  defp write_catalog!(names) do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path)
    "---\n" <> rest = File.read!(path)

    entries = Enum.map_join(names, "", &"  #{&1}:\n    image: registry.example.com/#{&1}:1\n")
    File.write!(path, "---\nenvironments:\n" <> entries <> rest)
    WorkflowStore.force_reload()
  end

  defp rejection_notes(identifier) do
    identifier |> Transcript.entries() |> Enum.filter(&(&1.text =~ "Environment rejected"))
  end

  test "a rejected environment is logged and noted once per distinct error, and stays skipped" do
    write_catalog!(["python"])
    issue = %Issue{id: "issue-env-1", identifier: "ENV-1", title: "T", state: "In Progress", labels: []}

    first =
      capture_log(fn ->
        assert {:error, state} = Orchestrator.do_dispatch_issue_for_test(%State{}, issue)
        send(self(), {:state, state})
      end)

    assert_received {:state, state}
    assert first =~ "Skipping dispatch; issue config resolution failed for issue_id=issue-env-1"
    assert first =~ "not in the platform catalog"
    assert [_note] = rejection_notes("ENV-1")

    # The next polls resolve again, stay skipped, and say nothing new.
    again =
      capture_log(fn ->
        assert {:error, state} = Orchestrator.do_dispatch_issue_for_test(state, issue)
        assert {:error, state} = Orchestrator.do_dispatch_issue_for_test(state, issue)
        send(self(), {:state, state})
      end)

    assert_received {:state, state}
    refute again =~ "Skipping dispatch; issue config resolution failed"
    assert [_note] = rejection_notes("ENV-1")

    # A different error for the same issue is reported again.
    write_catalog!(["python", "node"])

    changed =
      capture_log(fn ->
        assert {:error, state} = Orchestrator.do_dispatch_issue_for_test(state, issue)
        send(self(), {:state, state})
      end)

    assert_received {:state, state}
    assert changed =~ "available: node, python"
    assert [_first, _second] = rejection_notes("ENV-1")
    assert map_size(state.environment_rejections) == 2

    # Another issue with the same error is its own entry.
    other = %{issue | id: "issue-env-2", identifier: "ENV-2"}
    log = capture_log(fn -> assert {:error, _state} = Orchestrator.do_dispatch_issue_for_test(state, other) end)
    assert log =~ "issue_id=issue-env-2"
    assert [_note] = rejection_notes("ENV-2")
  end
end
