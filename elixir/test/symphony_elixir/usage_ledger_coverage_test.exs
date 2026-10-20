defmodule SymphonyElixir.UsageLedgerCoverageTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.UsageLedger

  @dirty_key {UsageLedger, :dirty}

  setup do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, UsageLedger)
    ledger_env = Application.get_env(:symphony_elixir, :usage_ledger_path, :unset)

    root = Path.join(System.tmp_dir!(), "symphony-usage-ledger-cov-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      case ledger_env do
        :unset -> Application.delete_env(:symphony_elixir, :usage_ledger_path)
        value -> Application.put_env(:symphony_elixir, :usage_ledger_path, value)
      end

      Supervisor.restart_child(SymphonyElixir.Supervisor, UsageLedger)
      UsageLedger.reset()
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "public API is a no-op while the ledger tables do not exist" do
    assert UsageLedger.snapshot() == %{usage: [], flow: %{edges: [], issues: []}}
    assert UsageLedger.projects() == %{}
    assert UsageLedger.reset() == :ok
    assert UsageLedger.observe_issue(%{identifier: "PAY-1"}) == :ok
    assert UsageLedger.record_tokens(%{issue: issue("PAY-1", "Todo")}, %{input_tokens: 1, output_tokens: 1}) == :ok
    assert UsageLedger.factory_node(:not_an_issue) == nil
    assert UsageLedger.factory_node(issue("PAY-1", "Something Else")) == nil
  end

  test "loads a persisted ledger, records changes, and flushes them back to disk", %{root: root} do
    path = Path.join(root, "usage.json")

    File.write!(
      path,
      Jason.encode!(%{
        version: 1,
        usage: [
          %{
            project: "proj",
            team: "PAY",
            issue: "PAY-1",
            backend: "codex",
            model: "gpt-5",
            title: "Loaded",
            project_name: "Project",
            url: "https://example.test/PAY-1",
            input_tokens: 10,
            output_tokens: nil
          }
        ],
        flow: %{
          edges: [%{from: "todo", to: "implement", count: 2}],
          issues: [%{issue: "PAY-1", id: "id-1", node: "implement", since_ms: 5, title: "Loaded", project: "proj"}]
        }
      })
    )

    pid = start_supervised!({UsageLedger, path: path})

    assert %{
             usage: [%{issue: "PAY-1", team: "PAY", model: "gpt-5", input_tokens: 10, output_tokens: 0, title: "Loaded"}],
             flow: %{
               edges: [%{from: "todo", to: "implement", count: 2}],
               issues: [%{issue: "PAY-1", id: "id-1", node: "implement", since_ms: 5, project: "proj", team: nil}]
             }
           } = UsageLedger.snapshot()

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex --model gpt-5.1 app-server")

    UsageLedger.record_tokens(
      %{issue: issue("nohyphen", "Todo"), backend: "codex"},
      %{input_tokens: 3, output_tokens: 4}
    )

    UsageLedger.record_tokens(%{issue: issue(nil, "Todo"), backend: "unknown"}, %{input_tokens: 1, output_tokens: 0})
    UsageLedger.observe_issue(issue("PAY-1", "Done"))

    assert :ok = UsageLedger.flush()

    persisted = path |> File.read!() |> Jason.decode!()
    assert persisted["version"] == 1

    rows = Enum.sort_by(persisted["usage"], &to_string(&1["issue"]))

    assert [
             %{"issue" => nil, "team" => nil, "backend" => "unknown", "model" => "default", "input_tokens" => 1},
             %{"issue" => "PAY-1", "input_tokens" => 10},
             %{"issue" => "nohyphen", "team" => nil, "model" => "gpt-5.1", "input_tokens" => 3, "output_tokens" => 4}
           ] = rows

    assert Enum.any?(persisted["flow"]["edges"], &match?(%{"from" => "implement", "to" => "done", "count" => 1}, &1))

    # the periodic flush message is handled without a dirty flag and keeps the file intact
    send(pid, :flush)
    assert %{path: ^path} = :sys.get_state(pid)
    assert File.read!(path) |> Jason.decode!() == persisted
  end

  test "logs when the persisted ledger is unreadable or cannot be written", %{root: root} do
    corrupt = Path.join(root, "corrupt.json")
    File.write!(corrupt, "{not json")

    log = capture_log(fn -> start_supervised!({UsageLedger, path: corrupt}) end)
    assert log =~ "Usage ledger load skipped path=#{corrupt}"
    assert UsageLedger.snapshot().usage == []
    stop_supervised!(UsageLedger)

    blocker = Path.join(root, "blocker")
    File.write!(blocker, "file")
    unwritable = Path.join([blocker, "nested", "usage.json"])
    start_supervised!({UsageLedger, path: unwritable})

    UsageLedger.observe_issue(issue("PAY-2", "Todo"))

    log = capture_log(fn -> assert :ok = UsageLedger.flush() end)
    assert log =~ "Usage ledger flush failed path=#{unwritable}"
    refute File.exists?(unwritable)
  end

  test "ignores empty token deltas, repeated observations, and a nil path" do
    start_supervised!({UsageLedger, path: nil})
    entry = %{issue: issue("PAY-4", "Todo"), backend: "claude"}

    assert UsageLedger.record_tokens(entry, %{input_tokens: 0, output_tokens: 0}) == :ok
    assert UsageLedger.snapshot().usage == []

    UsageLedger.observe_issue(issue("PAY-4", "Todo"))
    [%{since_ms: since}] = UsageLedger.snapshot().flow.issues
    UsageLedger.observe_issue(issue("PAY-4", " todo "))
    assert [%{node: "todo", since_ms: ^since}] = UsageLedger.snapshot().flow.issues
    assert UsageLedger.snapshot().flow.edges == []

    assert :ok = UsageLedger.flush()
  end

  test "tolerates a missing dirty flag and a missing ledger file", %{root: root} do
    path = Path.join(root, "missing.json")
    start_supervised!({UsageLedger, path: path})
    assert UsageLedger.snapshot().usage == []

    :persistent_term.erase(@dirty_key)
    UsageLedger.observe_issue(issue("PAY-3", "Todo"))
    assert [%{issue: "PAY-3", node: "todo"}] = UsageLedger.snapshot().flow.issues

    assert :ok = UsageLedger.flush()
    refute File.exists?(path)
  end

  test "uses the configured default path and never writes when nothing changed", %{root: root} do
    configured = Path.join(root, "configured.json")
    Application.put_env(:symphony_elixir, :usage_ledger_path, configured)
    {:ok, pid} = UsageLedger.start_link()
    assert Process.whereis(UsageLedger) == pid
    assert %{path: ^configured} = :sys.get_state(pid)
    GenServer.stop(pid)
    refute File.exists?(configured)

    Application.put_env(:symphony_elixir, :usage_ledger_path, :default)
    {:ok, pid} = UsageLedger.start_link(name: :usage_ledger_cov_default)
    assert :sys.get_state(pid).path == Path.expand("~/.symphony/usage.json")
    GenServer.stop(pid)
  end

  test "model_label falls back to default when settings are unavailable" do
    write_workflow_file!(Workflow.workflow_file_path(), claude_model: "sonnet", opencode_model: "")
    assert UsageLedger.model_label("claude") == "sonnet"
    assert UsageLedger.model_label("opencode") == "default"
    assert UsageLedger.model_label("codex") == "default"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "")
    assert_raise ArgumentError, fn -> Config.settings!() end
    assert UsageLedger.model_label("codex") == "default"
  end

  defp issue(identifier, state) do
    %Issue{id: "id-#{identifier}", identifier: identifier, title: "Task", state: state, project_slug: "proj", url: "https://example.test"}
  end
end
