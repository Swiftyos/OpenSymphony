defmodule SymphonyElixir.SessionHistoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.SessionHistory
  alias SymphonyElixirWeb.Visibility

  setup do
    SessionHistory.reset()
    previous = Application.get_env(:symphony_elixir, :session_history_path)

    on_exit(fn ->
      SessionHistory.reset()
      Application.put_env(:symphony_elixir, :session_history_path, previous)
    end)

    :ok
  end

  defp entry(identifier, project) do
    %{
      issue_id: "id-" <> identifier,
      identifier: identifier,
      issue_title: "Work on " <> identifier,
      state: "In Progress",
      project_slug: project,
      labels: [],
      backend: "claude",
      session_id: "s-1",
      turn_count: 3,
      started_at: DateTime.add(DateTime.utc_now(), -90, :second),
      last_agent_message: nil,
      last_agent_event: :turn_completed,
      agent_input_tokens: 10,
      agent_output_tokens: 5,
      agent_total_tokens: 15
    }
  end

  test "ended sessions are listed newest first with how they ended" do
    SessionHistory.record(entry("PAY-1", "checkout"), :finished)
    SessionHistory.record(entry("PAY-2", "checkout"), :stalled, "stalled for 300000ms")

    assert [second, first] = SessionHistory.list()
    assert %{issue_identifier: "PAY-2", outcome: "stalled", error: "stalled for 300000ms"} = second
    assert %{issue_identifier: "PAY-1", outcome: "finished", turn_count: 3, last_event: "turn_completed"} = first
    assert first.runtime_seconds >= 90
    assert first.tokens == %{input_tokens: 10, output_tokens: 5, total_tokens: 15}

    assert SessionHistory.list(since_ms: System.system_time(:millisecond) + 60_000) == []
  end

  test "sessions are kept across restarts when a path is set" do
    root = Path.join(System.tmp_dir!(), "symphony-session-history-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:symphony_elixir, :session_history_path, Path.join(root, "session_history.json"))
    on_exit(fn -> File.rm_rf(root) end)

    SessionHistory.record(entry("PAY-3", "checkout"), :closed)
    assert [_] = SessionHistory.list()

    reloaded = start_supervised!({SessionHistory, name: :reloaded_session_history}, id: :reloaded)
    assert [%{issue_identifier: "PAY-3", outcome: "closed", tokens: %{total_tokens: 15}}] = GenServer.call(reloaded, :list)
  end

  test "a project scope keeps only that project's sessions and flow" do
    payload = %{
      running: [%{issue_identifier: "PAY-1", project_slug: "checkout"}, %{issue_identifier: "PAY-2", project_slug: "billing"}],
      retrying: [],
      completed: [%{issue_identifier: "WEB-1", project_slug: "checkout"}, %{issue_identifier: "WEB-2", project_slug: "site"}],
      projects: [%{slug: "checkout"}, %{slug: "site"}],
      factory: %{
        usage: [%{issue: "PAY-1", project: "checkout"}, %{issue: "PAY-2", project: "billing"}],
        team: "PAY",
        teams: [%{key: "PAY", kind: "team"}, %{key: "project:checkout", kind: "project", slug: "checkout", teams: ["PAY"]}],
        definitions: %{"PAY" => %{}, "project:checkout" => %{}},
        flows: %{"PAY" => %{nodes: %{}}, "project:checkout" => %{nodes: %{}}}
      }
    }

    scoped = Visibility.scope_to_project(payload, "checkout")
    assert Enum.map(scoped.running, & &1.issue_identifier) == ["PAY-1"]
    assert Enum.map(scoped.completed, & &1.issue_identifier) == ["WEB-1"]
    assert scoped.counts == %{running: 1, retrying: 0}
    assert scoped.factory.team == "project:checkout"
    assert Map.keys(scoped.factory.flows) == ["project:checkout"]
    assert scoped.factory.usage == [%{issue: "PAY-1", project: "checkout"}]

    # A team scope narrows ended sessions too.
    assert Enum.map(Visibility.scope_to_team(payload, "WEB").completed, & &1.issue_identifier) == ["WEB-1", "WEB-2"]
  end
end
