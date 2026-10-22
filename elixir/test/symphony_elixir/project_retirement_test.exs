defmodule SymphonyElixir.ProjectRetirementTest do
  @moduledoc """
  Projects closed in Linear (completed, canceled, archived, deleted) close in
  Symphony: nothing new starts, work under way finishes, and then the project
  is removed as "Remove project" does, by "linear".
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Factory.Store
  alias SymphonyElixir.{ProjectRetirement, ProjectRoutes, Unblocker, UsageLedger}
  alias SymphonyElixirWeb.{FactoryPresenter, ScopePicker}

  setup do
    ProjectRoutes.reset()
    ProjectRetirement.reset()
    UsageLedger.reset()
    Store.reset()

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_project_statuses)
      ProjectRoutes.reset()
      ProjectRetirement.reset()
      UsageLedger.reset()
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_project_slug: nil,
      tracker_projects: [%{slug: "checkout"}, %{slug: "site"}]
    )

    :ok
  end

  defp statuses(map), do: Application.put_env(:symphony_elixir, :memory_tracker_project_statuses, map)

  defp observe(identifier, state, type, opts \\ []) do
    issue = %Issue{
      id: "id-" <> identifier,
      identifier: identifier,
      title: identifier,
      state: state,
      state_type: type,
      labels: Keyword.get(opts, :labels, []),
      project_slug: Keyword.get(opts, :project, "checkout"),
      blocked_by: Keyword.get(opts, :blocked_by, [])
    }

    UsageLedger.observe_issue(issue, external: true)
    issue
  end

  defp polled?(slug), do: Enum.any?(Config.linear_project_routes(), &(&1.slug == slug))

  test "a completed project waits for its work in progress, then retires once it is done" do
    observe("PAY-1", "In Progress", "started")
    todo = observe("PAY-2", "Todo", "unstarted")
    statuses(%{"checkout" => %{status: "completed"}})

    :ok = ProjectRetirement.check()
    assert %{"checkout" => %{reason: "completed in Linear", in_progress: 1}} = ProjectRetirement.closing()
    assert polled?("checkout")
    refute ProjectRoutes.removed?("checkout")

    # Nothing new starts: the Todo issue isn't picked up; PAY-1 carries on.
    assert ProjectRetirement.holds?(todo)
    refute ProjectRetirement.holds?(%Issue{id: "id-PAY-1", identifier: "PAY-1", state: "In Progress", project_slug: "checkout"})

    # The picker says so.
    projects = ScopePicker.projects(%{factory: FactoryPresenter.payload([], Config.settings!())}, nil)
    assert %{closing: %{in_progress: 1}} = Enum.find(projects, &(&1.slug == "checkout"))
    assert %{closing: nil} = Enum.find(projects, &(&1.slug == "site"))

    observe("PAY-1", "Done", "completed")
    :ok = ProjectRetirement.check()
    assert ProjectRetirement.closing() == %{}
    assert %{"checkout" => %{by: "linear", reason: "completed in Linear"}} = ProjectRoutes.removals()
    refute polled?("checkout")
    assert polled?("site")
    refute Enum.any?(ScopePicker.projects(%{factory: FactoryPresenter.payload([], Config.settings!())}, nil), &(&1.slug == "checkout"))
  end

  test "a canceled project with only Todo and Blocked issues retires at once" do
    observe("PAY-3", "Todo", "unstarted")
    observe("PAY-4", "In Progress", "started", labels: ["factory/blocked"])
    statuses(%{"checkout" => %{status: "canceled"}})

    :ok = ProjectRetirement.check()
    assert ProjectRetirement.closing() == %{}
    assert %{"checkout" => %{by: "linear", reason: "canceled in Linear"}} = ProjectRoutes.removals()
  end

  test "an archived project closes too, and blocked issues aren't unblocked while it does" do
    observe("PAY-5", "In Progress", "started")
    blocker = %Issue{id: "b1", identifier: "PAY-9", state: "Done", state_type: "completed"}
    blocked = observe("PAY-6", "In Progress", "started", labels: ["factory/blocked"], blocked_by: [blocker])
    statuses(%{"checkout" => %{archived: true}})

    :ok = ProjectRetirement.check()
    assert %{"checkout" => %{reason: "archived in Linear"}} = ProjectRetirement.closing()
    refute Unblocker.ready?(blocked)
  end

  test "re-opening the project in Linear cancels the closing" do
    observe("PAY-7", "In Review", "started")
    statuses(%{"checkout" => %{status: "completed"}})
    :ok = ProjectRetirement.check()
    assert ProjectRetirement.closing?("checkout")

    statuses(%{"checkout" => %{status: "started"}})
    :ok = ProjectRetirement.check()
    refute ProjectRetirement.closing?("checkout")
    refute ProjectRoutes.removed?("checkout")
    assert polled?("checkout")
  end

  test "a project missing from Linear once is not retired; missing twice in a row, it is deleted" do
    statuses(%{"checkout" => nil})
    :ok = ProjectRetirement.check()
    refute ProjectRetirement.closing?("checkout")
    refute ProjectRoutes.removed?("checkout")

    # Back, then missing again: the count starts over.
    statuses(%{})
    :ok = ProjectRetirement.check()
    statuses(%{"checkout" => nil})
    :ok = ProjectRetirement.check()
    refute ProjectRoutes.removed?("checkout")

    :ok = ProjectRetirement.check()
    assert %{"checkout" => %{by: "linear", reason: "deleted in Linear"}} = ProjectRoutes.removals()
    assert polled?("site")
  end
end
