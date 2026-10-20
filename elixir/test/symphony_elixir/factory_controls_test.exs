defmodule SymphonyElixir.FactoryControlsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{AgentRoute, FactoryControls, IssueStage, UsageLedger}
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory
  alias SymphonyElixirWeb.FactoryPresenter

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StubOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      totals = %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      {:reply, %{running: [], retrying: [], agent_totals: totals, rate_limits: nil}, state}
    end

    def handle_call(:request_refresh, _from, state), do: {:reply, %{queued: true}, state}
  end

  defmodule StageLinearClient do
    def graphql(query, variables, _opts \\ []) do
      send(self(), {:graphql_called, query, variables})
      [result | rest] = Process.get(:stage_results)
      Process.put(:stage_results, rest)
      result
    end
  end

  setup do
    FactoryControls.reset()
    UsageLedger.reset()
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    linear_client = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      FactoryControls.reset()
      UsageLedger.reset()
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
      restore_app_env(:memory_tracker_issues, memory_issues)
      restore_app_env(:linear_client_module, linear_client)
    end)

    :ok
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp issue(id, state, labels \\ []) do
    %Issue{id: "id-" <> id, identifier: id, title: "Task " <> id, state: state, labels: labels, project_slug: "project", url: "https://linear.app/x/" <> id}
  end

  defp empty_state(running \\ %{}) do
    %Orchestrator.State{
      max_concurrent_agents: 5,
      running: running,
      claimed: MapSet.new(),
      agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end

  test "controls validate input and default to no overrides" do
    assert FactoryControls.get("implement") == %{paused: false, max_agents: nil, backend: nil, effort: nil}
    assert {:ok, %{paused: true}} = FactoryControls.put("implement", "paused", true)
    assert {:ok, %{backend: "claude"}} = FactoryControls.put("implement", "backend", "claude")
    assert {:error, {:invalid_control, "backend", "gpt", _message}} = FactoryControls.put("implement", "backend", "gpt")
    assert {:error, {:unknown_stage, "review"}} = FactoryControls.put("review", "paused", true)
    assert {:error, {:invalid_control, "max_agents", 0, _message}} = FactoryControls.put("merge", "max_agents", 0)
  end

  test "pausing a stage stops new dispatch but leaves running agents alone" do
    write_workflow_file!(Workflow.workflow_file_path())
    {:ok, _} = FactoryControls.put("merge", "paused", true)

    refute Orchestrator.should_dispatch_issue_for_test(issue("MT-1", "In Progress", ["factory/merge"]), empty_state())
    assert Orchestrator.should_dispatch_issue_for_test(issue("MT-2", "In Progress"), empty_state())

    agent = spawn(fn -> receive do: (:stop -> :ok) end)
    merge_issue = issue("MT-1", "In Progress", ["factory/merge"])
    running = %{"id-MT-1" => %{pid: agent, ref: nil, identifier: "MT-1", issue: merge_issue, started_at: DateTime.utc_now()}}
    state = Orchestrator.reconcile_issue_states_for_test([issue("MT-1", "In Progress", ["factory/merge"])], empty_state(running))

    assert Map.has_key?(state.running, "id-MT-1")
    assert Process.alive?(agent)
  end

  test "stage caps limit concurrent agents in that stage only" do
    write_workflow_file!(Workflow.workflow_file_path())
    {:ok, _} = FactoryControls.put("merge", "max_agents", 1)

    running = %{"id-MT-3" => %{pid: self(), ref: nil, identifier: "MT-3", issue: issue("MT-3", "In Progress", ["factory/merge"])}}

    refute Orchestrator.should_dispatch_issue_for_test(issue("MT-4", "In Progress", ["factory/merge"]), empty_state(running))
    assert Orchestrator.should_dispatch_issue_for_test(issue("MT-5", "In Progress"), empty_state(running))
  end

  test "stage harness and thinking apply unless the issue has its own labels" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "codex", default_effort: "low")
    {:ok, _} = FactoryControls.put("rework", "backend", "claude")
    {:ok, _} = FactoryControls.put("rework", "effort", "high")

    route = AgentRoute.resolve(issue("MT-6", "In Progress", ["factory/rework"]))
    assert {route.backend, route.effort} == {"claude", "high"}

    labelled = AgentRoute.resolve(issue("MT-7", "In Progress", ["factory/rework", "codex", "thinking/max"]))
    assert {labelled.backend, labelled.effort} == {"codex", "max"}

    other_stage = AgentRoute.resolve(issue("MT-8", "In Progress"))
    assert {other_stage.backend, other_stage.effort} == {"codex", "low"}
  end

  test "ledger records tokens per harness and counts stage transitions" do
    write_workflow_file!(Workflow.workflow_file_path())

    UsageLedger.observe_issue(issue("PAY-1", "Todo"))
    UsageLedger.observe_issue(issue("PAY-1", "In Progress"))
    UsageLedger.observe_issue(issue("PAY-1", "In Review"))
    UsageLedger.observe_issue(issue("PAY-1", "In Progress", ["factory/rework"]))
    UsageLedger.observe_issue(issue("PAY-1", "In Progress", ["factory/rework"]))

    entry = %{issue: issue("PAY-1", "In Progress"), backend: "claude"}
    UsageLedger.record_tokens(entry, %{input_tokens: 1_000_000, output_tokens: 100_000})
    UsageLedger.record_tokens(entry, %{input_tokens: 500_000, output_tokens: 0})

    %{usage: [row], flow: flow} = UsageLedger.snapshot()
    assert {row.team, row.backend, row.input_tokens, row.output_tokens} == {"PAY", "claude", 1_500_000, 100_000}
    assert %{team: "PAY", project: "project", from: "review", to: "rework", count: 1} in flow.edges
    assert [%{node: "rework"}] = flow.issues

    settings = %{Config.settings!() | pricing: %{"claude" => %{"input_per_mtok" => 3, "output_per_mtok" => 15}}}
    payload = FactoryPresenter.payload([], settings)
    assert [%{cost_usd: cost}] = payload.usage
    assert_in_delta cost, 6.0, 0.0001
    assert payload.priced
  end

  test "server.controls: false is a read-only kill switch" do
    write_workflow_file!(Workflow.workflow_file_path())
    settings = Config.settings!()

    assert FactoryPresenter.controls_enabled?(%{settings | server: %{settings.server | controls: nil}})
    refute FactoryPresenter.controls_enabled?(%{settings | server: %{settings.server | controls: false}})
  end

  test "memory tracker set_stage swaps the stage label and state" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("MT-9", "In Review", ["claude", "factory/implement"])])

    assert :ok = Memory.set_stage("id-MT-9", "In Progress", "merge")
    assert [%Issue{state: "In Progress", labels: ["claude", "factory/merge"]}] = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("MT-9", "In Progress", ["factory/merge", "Needs-Approval"])])
    assert :ok = Memory.set_stage("id-MT-9", "Done", nil, drop_labels: ["needs-approval"])
    assert [%Issue{state: "Done", labels: []}] = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    assert :ok = SymphonyElixir.Tracker.set_stage("id-MT-9", "In Progress", "merge")
  end

  test "linear set_stage keeps other labels and picks the team's stage label" do
    write_workflow_file!(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :linear_client_module, StageLinearClient)

    lookup = %{
      "data" => %{
        "issue" => %{
          "team" => %{"id" => "team-1", "states" => %{"nodes" => [%{"id" => "state-ip"}]}},
          "labels" => %{
            "nodes" => [
              %{"id" => "lbl-claude", "name" => "claude", "parent" => nil},
              %{"id" => "lbl-impl", "name" => "implement", "parent" => %{"name" => "factory"}}
            ]
          }
        },
        "issueLabels" => %{"nodes" => [%{"id" => "lbl-other-team", "team" => %{"id" => "team-2"}}, %{"id" => "lbl-merge", "team" => %{"id" => "team-1"}}]}
      }
    }

    Process.put(:stage_results, [{:ok, lookup}, {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}])

    assert :ok = Adapter.set_stage("issue-uuid", "In Progress", "merge")
    assert_receive {:graphql_called, _lookup_query, %{flat: "factory/merge", stage: "merge"}}
    assert_receive {:graphql_called, _mutation, %{stateId: "state-ip", labelIds: ["lbl-claude", "lbl-merge"]}}

    Process.put(:stage_results, [{:ok, put_in(lookup, ["data", "issueLabels", "nodes"], [])}])
    assert {:error, {:stage_label_not_found, "factory/rework"}} = Adapter.set_stage("issue-uuid", "In Progress", "rework")
  end

  describe "dashboard controls" do
    setup do
      name = Module.concat(__MODULE__, :Orchestrator)
      {:ok, _pid} = StubOrchestrator.start_link(name: name)

      endpoint_config =
        :symphony_elixir
        |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
        |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: name, snapshot_timeout_ms: 200)

      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
      start_supervised!({SymphonyElixirWeb.Endpoint, []})
      :ok
    end

    test "stage controls apply from the dashboard and reply with the new value" do
      write_workflow_file!(Workflow.workflow_file_path())
      {:ok, view, html} = live(build_conn(), "/")
      assert html =~ "Needs you"
      assert html =~ ~s(data-fx="diagram")

      render_hook(view, "factory_control", %{"team" => "MT", "stage" => "implement", "field" => "paused", "value" => true})
      assert_reply(view, %{ok: true, controls: %{paused: true}})
      assert FactoryControls.paused?({"MT", "implement"})

      render_hook(view, "factory_control", %{"team" => "MT", "stage" => "implement", "field" => "max_agents", "value" => -1})
      assert_reply(view, %{ok: false})
    end

    test "issue moves update the tracker and the flow immediately" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("MT-10", "In Review")])
      UsageLedger.observe_issue(issue("MT-10", "In Review"))

      {:ok, view, _html} = live(build_conn(), "/")
      render_hook(view, "factory_move", %{"id" => "id-MT-10", "to" => "merge"})
      assert_reply(view, %{ok: true})

      assert [%Issue{state: "In Progress", labels: ["factory/merge"]}] = Application.get_env(:symphony_elixir, :memory_tracker_issues)
      assert [%{issue: "MT-10", node: "merge"}] = UsageLedger.snapshot().flow.issues
      assert IssueStage.stage(issue("MT-10", "In Progress", ["factory/merge"])) == "merge"
    end
  end
end
