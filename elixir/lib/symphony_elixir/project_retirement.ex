defmodule SymphonyElixir.ProjectRetirement do
  @moduledoc """
  Retires projects that were closed in Linear: archived or deleted, or whose
  status moved to completed or canceled.

  On every poll interval it asks Linear for the status of each project
  Symphony polls (one request for all of them). A closed project first
  **closes**: no new work starts in it (nothing is picked up from a queue
  stage such as Todo, and blocked issues aren't unblocked) while the work
  already under way finishes. Once none of its issues is in progress (each is
  in a queue stage like Todo, a parked stage like Blocked, done, canceled or
  backlog), it is removed from Symphony exactly as "Remove project" does
  (`SymphonyElixir.ProjectRoutes.remove/3`, recorded `by: "linear"`): no
  longer polled or routed, its project flow dropped, gone from the pickers,
  its history kept.

  A project Linear no longer returns counts as deleted only after it is
  missing from two successful lookups in a row, so one bad answer never
  retires anything; a failed lookup changes nothing. Re-opening the project
  in Linear before it is retired cancels the closing.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, IssueStage, ProjectRoutes, Tracker, UsageLedger}
  alias SymphonyElixir.Factory.{Definition, Store}

  @table :symphony_project_retirement
  @missing_polls 2
  @closed_statuses ["completed", "canceled"]
  # Linear state types an issue isn't in progress in.
  @settled_types ["triage", "backlog", "unstarted", "completed", "canceled"]

  @type closing :: %{reason: String.t(), since: String.t(), in_progress: non_neg_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Projects closing in Linear, by slug."
  @spec closing() :: %{String.t() => closing()}
  def closing do
    case ready?() && :ets.lookup(@table, :closing) do
      [{:closing, closing}] -> closing
      _ -> %{}
    end
  end

  @spec closing?(String.t() | nil) :: boolean()
  def closing?(slug) when is_binary(slug), do: Map.has_key?(closing(), slug)
  def closing?(_slug), do: false

  @doc """
  Whether a closing project holds this issue back: one waiting in a queue
  stage (Todo) isn't picked up. Work already in its later stages goes on.
  """
  @spec holds?(SymphonyElixir.Linear.Issue.t()) :: boolean()
  def holds?(%{project_slug: slug} = issue) when is_binary(slug) do
    closing?(slug) and match?(%{"kind" => "queue"}, IssueStage.stage_definition(issue))
  end

  def holds?(_issue), do: false

  @doc "Runs one check now (tests; the server also runs it every poll interval)."
  @spec check() :: :ok
  def check, do: GenServer.call(__MODULE__, :check, 30_000)

  @doc false
  @spec reset() :: :ok
  def reset do
    if ready?(), do: GenServer.call(__MODULE__, :reset)
    :ok
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    :ets.insert(@table, {:closing, %{}})
    interval = Keyword.get(opts, :interval_ms, Application.get_env(:symphony_elixir, :project_retirement_interval_ms, :poll))
    state = %{missing: %{}, interval: interval}
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    state = run_check(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:check, _from, state), do: {:reply, :ok, run_check(state)}

  def handle_call(:reset, _from, state) do
    :ets.insert(@table, {:closing, %{}})
    {:reply, :ok, %{state | missing: %{}}}
  end

  defp schedule(%{interval: :poll}) do
    ms = Config.settings!().polling.interval_ms
    Process.send_after(self(), :check, ms)
  rescue
    _error -> Process.send_after(self(), :check, 30_000)
  end

  defp schedule(%{interval: ms}) when is_integer(ms) and ms > 0, do: Process.send_after(self(), :check, ms)
  defp schedule(_state), do: :ok

  defp run_check(state) do
    slugs = Config.linear_project_routes() |> Enum.map(& &1.slug) |> Enum.uniq()

    case slugs != [] && Tracker.project_statuses(slugs) do
      {:ok, statuses} ->
        {closed, missing} = closed_projects(slugs, statuses, state.missing)
        update_closing(closed)
        %{state | missing: missing}

      false ->
        update_closing(%{})
        state

      {:error, reason} ->
        Logger.debug("Project status check skipped reason=#{inspect(reason, limit: 5)}")
        state
    end
  rescue
    error ->
      Logger.warning("Project status check failed: #{Exception.message(error)}")
      state
  end

  # The projects Linear closed, with why; and how many lookups in a row each
  # missing one has been missing from.
  defp closed_projects(slugs, statuses, missing) do
    Enum.reduce(slugs, {%{}, %{}}, fn slug, {closed, still_missing} ->
      case closed_reason(Map.fetch(statuses, slug), Map.get(missing, slug, 0) + 1) do
        {:missing, count, nil} -> {closed, Map.put(still_missing, slug, count)}
        {:missing, count, reason} -> {Map.put(closed, slug, reason), Map.put(still_missing, slug, count)}
        nil -> {closed, still_missing}
        reason -> {Map.put(closed, slug, reason), still_missing}
      end
    end)
  end

  defp closed_reason({:ok, %{archived: true}}, _count), do: "archived in Linear"
  defp closed_reason({:ok, %{status: status}}, _count) when status in @closed_statuses, do: "#{status} in Linear"
  defp closed_reason({:ok, _open}, _count), do: nil
  defp closed_reason(:error, count), do: {:missing, count, if(count >= @missing_polls, do: "deleted in Linear")}

  defp update_closing(closed) do
    previous = closing()

    for slug <- Map.keys(previous) -- Map.keys(closed) do
      Logger.info("Project re-opened in Linear; retirement cancelled slug=#{slug}")
    end

    issues = UsageLedger.snapshot().flow.issues

    still_closing =
      Enum.reduce(closed, %{}, fn {slug, reason}, acc ->
        in_progress = Enum.count(issues, &(&1.project == slug and in_progress?(&1)))
        settle(acc, slug, reason, in_progress, previous[slug])
      end)

    :ets.insert(@table, {:closing, still_closing})
  end

  # No work in progress: retired. Otherwise it keeps closing (since it first did).
  defp settle(acc, slug, reason, 0, _previous) do
    retire(slug, reason)
    acc
  end

  defp settle(acc, slug, reason, in_progress, nil) do
    Logger.info("Project closing: #{reason}; waiting for #{in_progress} issue(s) in progress slug=#{slug}")
    since = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    Map.put(acc, slug, %{reason: reason, since: since, in_progress: in_progress})
  end

  defp settle(acc, slug, reason, in_progress, previous),
    do: Map.put(acc, slug, %{reason: reason, since: previous.since, in_progress: in_progress})

  defp retire(slug, reason) do
    :ok = ProjectRoutes.remove(slug, "linear", reason)
    Logger.info("Project retired: #{reason}, no work in progress slug=#{slug} by=linear")
    SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()
  end

  # In progress: a started Linear state, unless its stage parks it (Blocked).
  defp in_progress?(issue) do
    type = issue[:state_type]

    cond do
      type in @settled_types -> false
      issue.node in ["canceled", "backlog"] -> false
      true -> not settled_stage?(issue)
    end
  end

  defp settled_stage?(issue) do
    definition = Store.get(Store.scope_for(issue.team, issue.project), issue.team)
    match?(%{"kind" => kind} when kind in ["queue", "parked", "done"], Definition.stage(definition, issue.node))
  end

  defp ready?, do: :ets.whereis(@table) != :undefined
end
