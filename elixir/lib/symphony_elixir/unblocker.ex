defmodule SymphonyElixir.Unblocker do
  @moduledoc """
  Moves an issue out of its flow's blocked stage once everything blocking it is
  done, and says on the issue what the blockers did.

  An agent that finds the fix belongs in another repo files an issue for that
  repo, links it as blocking its own issue, and moves its issue to the blocked
  stage (`SymphonyElixir.RepoPrompt`). Each poll hands the candidate issues to
  `observe/1`. An issue qualifies when it is in a `parked` stage, has at least
  one Linear blocker, and every blocker is completed (Linear state type
  `completed`; a cancelled blocker keeps it blocked for a person to decide).

  For each one, in the background:

    1. re-reads the issue, so a move someone already made isn't undone
    2. reads the blockers: title, link, PRs and their Agent Factory summaries
    3. posts an `## Unblocked` comment with that (idempotent: one per issue and
       set of blockers), which the next stage reads like any stage comment
    4. moves the issue to the stage it was blocked from when the flow allows
       that, else to the first agent stage the blocked stage leads to

  A parked issue with no blockers stays where it is for a person, as before.
  Symphony unblocks an issue once per set of blockers, so a person who parks it
  again afterwards keeps it parked (until a restart).
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Effects, IssueStage, Orchestrator, Tracker, UsageLedger}
  alias SymphonyElixir.Factory.Definition
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.ObservabilityPubSub

  @resume_kinds ["agent", "queue"]
  @max_summaries 3
  @max_summary 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Looks at a poll's issues and unblocks the ones whose blockers are all done.
  Returns at once; the work happens in the background.
  """
  @spec observe([Issue.t()]) :: :ok
  def observe(issues) when is_list(issues) do
    case {Process.whereis(__MODULE__), Enum.filter(issues, &ready?/1)} do
      {nil, _} -> :ok
      {_pid, []} -> :ok
      {pid, ready} -> GenServer.cast(pid, {:observe, ready})
    end
  end

  @doc """
  Whether an issue is in a parked stage with blockers that are all done, and
  its flow has somewhere to send it back to.
  """
  @spec ready?(Issue.t()) :: boolean()
  def ready?(%Issue{blocked_by: [_ | _] = blockers} = issue) do
    case IssueStage.stage_definition(issue) do
      %{"kind" => "parked"} -> Enum.all?(blockers, &completed?/1) and resume_target(issue) != nil
      _ -> false
    end
  end

  def ready?(_issue), do: false

  @doc """
  The stage an unblocked issue goes back to: the one it was blocked from, if
  the blocked stage leads back there, else the first agent stage it leads to.
  """
  @spec resume_target(Issue.t()) :: map() | nil
  def resume_target(%Issue{} = issue) do
    definition = IssueStage.definition(issue)

    with %{"id" => from} <- IssueStage.stage_definition(issue) do
      targets =
        for transition <- Definition.transitions_from(definition, from),
            %{"kind" => kind} = stage <- [Definition.stage(definition, transition["to"])],
            kind in @resume_kinds,
            do: stage

      previous = UsageLedger.previous_node(issue.identifier)
      Enum.find(targets, &(&1["id"] == previous)) || Enum.find(targets, &(&1["id"] == "implement")) || List.first(targets)
    end
  end

  @doc """
  The comment posted when an issue is unblocked.
  """
  @spec comment(Issue.t(), [map()], map()) :: String.t()
  def comment(%Issue{} = issue, reports, target) do
    blockers = Enum.map_join(reports, "\n\n", &blocker_section/1)

    """
    ## Unblocked

    Every issue blocking #{issue.identifier} is done, so Agent Factory moved it back to **#{target["name"]}**. \
    Here is what was done; build on it, and check the other repos (refreshed to their latest default branch) for the changes.

    #{blockers}
    """
  end

  @impl true
  def init(_opts), do: {:ok, %{in_flight: %{}, done: MapSet.new()}}

  @impl true
  def handle_cast({:observe, issues}, state) do
    busy = state.in_flight |> Map.values() |> MapSet.new(&elem(&1, 0))

    in_flight =
      issues
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(&{&1, comment_id(&1)})
      |> Enum.reject(fn {issue, key} -> MapSet.member?(busy, issue.id) or MapSet.member?(state.done, key) end)
      |> Enum.reduce(state.in_flight, fn {issue, key}, acc ->
        task = Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn -> unblock(issue) end)
        Map.put(acc, task.ref, {issue.id, key})
      end)

    {:noreply, %{state | in_flight: in_flight}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {entry, in_flight} = Map.pop(state.in_flight, ref)
    done = if result == :ok and entry, do: MapSet.put(state.done, elem(entry, 1)), else: state.done
    {:noreply, %{state | in_flight: in_flight, done: done}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.in_flight, ref) do
      {{issue_id, _key}, in_flight} ->
        Logger.warning("Unblock task crashed issue_id=#{issue_id} reason=#{inspect(reason)}")
        {:noreply, %{state | in_flight: in_flight}}

      {nil, _in_flight} ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  @spec unblock(Issue.t()) :: :ok | :skipped | {:error, term()}
  def unblock(%Issue{} = seen) do
    with {:ok, %Issue{} = issue} <- refetch(seen),
         true <- (IssueStage.stage(issue) == IssueStage.stage(seen) and ready?(issue)) || :skipped,
         %{} = target <- resume_target(issue),
         {:ok, reports} <- Tracker.fetch_issue_reports(Enum.map(issue.blocked_by, & &1.id)),
         :ok <- Tracker.create_comment(issue.id, comment(issue, order(reports, issue.blocked_by), target), id: comment_id(issue)),
         :ok <- Tracker.set_stage(issue.id, target["linear_state"], target["label"], drop_labels: [IssueStage.approval_label()]) do
      Logger.info("Unblocked #{issue.identifier} to=#{target["id"]} blockers=#{Enum.map_join(issue.blocked_by, ",", & &1.identifier)}")
      UsageLedger.observe_issue(%{issue | state: target["linear_state"], labels: stage_labels(issue.labels, target["label"])})
      Orchestrator.request_refresh_async()
      ObservabilityPubSub.broadcast_update()
      :ok
    else
      :skipped ->
        :skipped

      {:error, reason} ->
        Logger.warning("Unblock failed issue_identifier=#{seen.identifier} reason=#{inspect(reason)}")
        {:error, reason}

      _ ->
        :skipped
    end
  end

  defp refetch(%Issue{id: id}) do
    case Tracker.fetch_issue_states_by_ids([id]) do
      {:ok, [%Issue{} = issue | _]} -> {:ok, issue}
      {:ok, []} -> :skipped
      {:error, reason} -> {:error, reason}
    end
  end

  defp completed?(%{state_type: type}) when is_binary(type), do: String.downcase(type) == "completed"
  defp completed?(%{state: state}) when is_binary(state), do: String.downcase(String.trim(state)) == "done"
  defp completed?(_blocker), do: false

  # One comment per issue, blocked stage and set of blockers, so a retry after a
  # failed move doesn't post it twice. Also the key for "already unblocked".
  defp comment_id(issue) do
    blockers = issue.blocked_by |> Enum.map(& &1.id) |> Enum.sort() |> Enum.join(",")
    Effects.uuid("unblock:#{issue.id}:#{IssueStage.stage(issue)}:#{blockers}")
  end

  defp order(reports, blockers) do
    by_id = Map.new(reports, &{&1.id, &1})
    for blocker <- blockers, do: Map.get(by_id, blocker.id) || %{identifier: blocker.identifier, title: nil, url: nil, state: blocker.state, attachments: [], comments: []}
  end

  defp blocker_section(report) do
    title = if is_binary(report[:title]), do: " · " <> escape_markdown(report.title), else: ""
    link = if is_binary(report[:url]), do: "\n#{report.url}", else: ""

    "### #{report[:identifier]}#{title} (#{report[:state] || "done"})#{link}" <>
      links_line(report[:attachments] || []) <> summaries_block(stage_summaries(report[:comments] || []))
  end

  defp links_line([]), do: ""
  defp links_line(attachments), do: "\n\n**Links:** " <> Enum.map_join(attachments, ", ", &"[#{escape_markdown(&1.title || &1.url)}](#{&1.url})")

  defp summaries_block([]), do: "\n\nNo Agent Factory summary on it; read the issue for what changed."
  defp summaries_block(summaries), do: "\n\n" <> Enum.join(summaries, "\n\n")

  # Agent Factory stage comments are `## <stage>` headed and end in a
  # "Moved to ... by Agent Factory" note. Keep the newest per stage.
  defp stage_summaries(comments) do
    comments
    |> Enum.filter(&(String.starts_with?(&1, "## ") and String.contains?(&1, "by Agent Factory")))
    |> Enum.reject(&String.starts_with?(&1, "## Unblocked"))
    |> Enum.uniq_by(&(&1 |> String.split("\n", parts: 2) |> hd()))
    |> Enum.take(@max_summaries)
    |> Enum.map(&quote_summary/1)
  end

  defp quote_summary(body) do
    [heading | rest] = String.split(body, "\n", parts: 2)

    text =
      rest
      |> List.first("")
      |> String.replace(~r/\n*_Moved to [^\n]*by Agent Factory[^\n]*_\s*\z/, "")
      |> String.trim()
      |> truncate()

    "**#{String.trim_leading(heading, "# ")}:**\n" <> Enum.map_join(String.split(text, "\n"), "\n", &("> " <> &1))
  end

  defp truncate(text) do
    if String.length(text) > @max_summary, do: String.slice(text, 0, @max_summary) <> "…", else: text
  end

  defp stage_labels(labels, label) do
    prefix = IssueStage.label_prefix() <> "/"
    kept = Enum.reject(labels, &(String.starts_with?(String.downcase(&1), prefix) or String.downcase(&1) == IssueStage.approval_label()))
    if label, do: kept ++ [prefix <> String.downcase(label)], else: kept
  end

  # Linear titles are user-controlled; keep them from adding links or formatting.
  defp escape_markdown(text), do: String.replace(to_string(text), ~r/([\\`*_{}\[\]()#+\-.!|<>~])/, "\\\\\\1")
end
