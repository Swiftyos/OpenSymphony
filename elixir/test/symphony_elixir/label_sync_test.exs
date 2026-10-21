defmodule SymphonyElixir.LabelSyncTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Factory.{Definition, Store}
  alias SymphonyElixir.{LabelSync, Tracker}
  alias SymphonyElixir.Linear.{Adapter, Issue}

  defmodule FakeLinear do
    def graphql(query, variables, _opts \\ []) do
      send(Application.get_env(:symphony_elixir, :fake_linear_recipient), {:graphql, query, variables})
      Application.get_env(:symphony_elixir, :fake_linear_reply).(query, variables)
    end
  end

  setup do
    Store.reset()
    keys = [:linear_client_module, :fake_linear_recipient, :fake_linear_reply, :label_sync_on_boot]
    saved = Map.new(keys, &{&1, Application.get_env(:symphony_elixir, &1)})
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinear)
    Application.put_env(:symphony_elixir, :fake_linear_recipient, self())

    on_exit(fn ->
      Store.reset()
      :persistent_term.erase({LabelSync, :project_names})
      :persistent_term.erase({LabelSync, :project_teams})

      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:symphony_elixir, key)
        {key, value} -> Application.put_env(:symphony_elixir, key, value)
      end)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "k",
      tracker_project_slug: "checkout"
    )

    :ok
  end

  defp reply(fun), do: Application.put_env(:symphony_elixir, :fake_linear_reply, fun)

  defp linear(opts) do
    existing_plain = Keyword.get(opts, :plain, [])
    project_reply = Keyword.get(opts, :projects, {:ok, %{"data" => %{"projects" => %{"nodes" => [%{"slugId" => "checkout", "name" => "Checkout API", "teams" => %{"nodes" => [%{"key" => "OPS"}]}}]}}}})

    reply(fn query, variables ->
      cond do
        query =~ "SymphonyProjectTeams" -> project_reply
        query =~ "SymphonyStageLabels" -> {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "t1"}]}, "issueLabels" => %{"nodes" => []}}}}
        query =~ "SymphonyPlainLabels" -> {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "t1", "labels" => %{"nodes" => existing_plain}}]}, "issueLabels" => %{"nodes" => []}}}}
        query =~ "SymphonyCreateLabel" -> {:ok, %{"data" => %{"issueLabelCreate" => %{"success" => true, "issueLabel" => %{"id" => "new-" <> variables.input.name}}}}}
      end
    end)
  end

  test "creates the stage group, the project flow's stage labels, and the plain labels for each project team" do
    flow = Definition.default_template() |> Map.update!("stages", &(&1 ++ [%{"id" => "research", "name" => "Research", "kind" => "agent", "linear_state" => "In Progress", "label" => "research"}]))
    {:ok, _} = Store.put("project:checkout", flow, 0, "mia")
    linear(plain: [%{"name" => "Bug"}])

    assert {:ok, %{"OPS" => created}} = LabelSync.sync()
    assert "factory" in created
    assert "factory/research" in created
    assert "factory/merge" in created
    assert "needs-approval" in created
    assert_receive {:graphql, _, %{slugs: ["checkout"]}}
    assert_receive {:graphql, _, %{input: %{name: "needs-approval", teamId: "t1"}}}
    # The project's Linear name is remembered for the dashboard.
    assert LabelSync.project_names()["checkout"] == "Checkout API"
  end

  test "a flow without stage labels only needs the plain labels" do
    plain_flow = %{
      "stages" => [
        %{"id" => "todo", "name" => "Todo", "kind" => "queue", "linear_state" => "Todo"},
        %{"id" => "done", "name" => "Done", "kind" => "done", "linear_state" => "Done"}
      ],
      "transitions" => [%{"from" => "todo", "to" => "done", "by" => "agent"}]
    }

    {:ok, _} = Store.put("project:checkout", plain_flow, 0, "mia")
    linear([])

    assert {:ok, %{"OPS" => ["needs-approval"]}} = LabelSync.sync()
    refute_received {:graphql, _, %{prefix: _}}
  end

  test "labels the team or workspace already has are left alone" do
    linear(plain: [%{"name" => "Needs-Approval"}])
    assert {:ok, %{"OPS" => created}} = LabelSync.sync()
    refute "needs-approval" in created
    assert Adapter.ensure_labels("OPS", ["needs-approval", "NEEDS-APPROVAL"]) == {:ok, []}
  end

  test "failures are logged, not raised" do
    linear(projects: {:error, :down})
    assert capture_log(fn -> assert {:error, :down} = LabelSync.sync() end) =~ "couldn't look up project teams"

    linear(projects: {:ok, %{"data" => nil}})
    assert {:error, {:unexpected_response, _}} = Adapter.project_info(["checkout"])
    assert {:ok, %{}} = Adapter.project_info([])

    projects = {:ok, %{"data" => %{"projects" => %{"nodes" => [%{"slugId" => "checkout", "name" => "Checkout API", "teams" => %{"nodes" => [%{"key" => "OPS"}]}}]}}}}

    reply(fn query, _variables ->
      if query =~ "SymphonyProjectTeams", do: projects, else: {:ok, %{"data" => %{"teams" => %{"nodes" => []}}}}
    end)

    assert capture_log(fn -> assert {:ok, %{"OPS" => []}} = LabelSync.sync() end) =~ "Linear label sync failed team=OPS"

    plain = {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "t1", "labels" => %{"nodes" => []}}]}, "issueLabels" => %{"nodes" => []}}}}
    reply(fn query, _variables -> if query =~ "SymphonyPlainLabels", do: plain, else: {:error, :boom} end)

    assert Adapter.ensure_labels("OPS", ["auto-build"]) == {:error, :boom}
  end

  test "boot only syncs for the Linear tracker and when enabled" do
    linear([])
    Application.put_env(:symphony_elixir, :label_sync_on_boot, true)
    assert LabelSync.boot() == :ok
    assert_receive {:graphql, _, %{slugs: ["checkout"]}}

    Application.put_env(:symphony_elixir, :label_sync_on_boot, false)
    assert LabelSync.boot() == :ok
    refute_receive {:graphql, _, %{slugs: _}}

    assert %{id: LabelSync, restart: :temporary} = LabelSync.child_spec([])
  end

  test "the memory tracker answers from its issues" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    issue = %Issue{id: "1", identifier: "PAY-1", project_slug: "checkout", project_name: "Checkout"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    assert Tracker.project_info(["checkout", "none"]) == {:ok, %{"checkout" => %{name: "Checkout", teams: ["PAY"]}, "none" => %{name: nil, teams: []}}}
    assert Tracker.ensure_labels("PAY", ["auto-build"]) == {:ok, []}
  after
    Application.delete_env(:symphony_elixir, :memory_tracker_issues)
  end
end
