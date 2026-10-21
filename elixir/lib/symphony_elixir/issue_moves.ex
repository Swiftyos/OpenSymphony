defmodule SymphonyElixir.IssueMoves do
  @moduledoc """
  Moving issues between factory stages on someone's behalf, and reviewing moves
  an agent made, shared by the dashboard and the MCP endpoint.

  Only the issue and the target stage come from the caller. The issue (team,
  project, labels, current stage) is read back from the tracker, the person
  must be allowed to move it, and the move must be a connection in its flow.
  Callers resolve the user freshly and check `server.controls` first.

  Options:

    * `:actor` - who to record in the flow's history (defaults to the username)
    * `:via` - where the move came from, for the Linear comment
      (`"from the dashboard"` by default)
  """

  require Logger

  alias SymphonyElixir.{Auth, Config, IssueStage, Orchestrator, StageResult, Tracker, UsageLedger}
  alias SymphonyElixir.Factory.{Definition, Store}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.ObservabilityPubSub

  @doc """
  Moves an issue (Linear id, or an identifier such as `PAY-12` that Symphony has
  seen) to stage `to` of its flow.
  """
  @spec move(Auth.User.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def move(%Auth.User{} = user, id, to, opts) when is_binary(id) and is_binary(to) do
    with {:ok, %Issue{} = issue} <- fetch_movable_issue(id),
         true <- Auth.can_move_issue?(user, issue.identifier, issue.project_slug) || {:error, :not_team_member},
         {:ok, target} <- allowed_move(user, issue, to),
         approval = IssueStage.approval_label(),
         :ok <- Tracker.set_stage(issue.id, target["linear_state"], target["label"], drop_labels: [approval]) do
      record_move(issue.id, user, target, opts)
      labels = issue.labels |> replace_stage_label(target["label"]) |> Enum.reject(&(String.downcase(&1) == approval))
      UsageLedger.observe_issue(%{issue | state: target["linear_state"], labels: labels})
      StageResult.finished(issue, target, IssueStage.definition(issue))

      Orchestrator.request_refresh_async()
      ObservabilityPubSub.broadcast_update()
      :ok
    end
  end

  @doc """
  A held issue: the agent already made its move. `:approved` keeps it (and
  counts toward the stage's earned autonomy); `:sent_back` returns the issue to
  the stage the agent moved it from (and resets that count).
  """
  @spec review(Auth.User.t(), String.t(), :approved | :sent_back, keyword()) :: :ok | {:error, term()}
  def review(%Auth.User{} = user, id, verdict, opts) when verdict in [:approved, :sent_back] do
    approval = IssueStage.approval_label()

    with {:ok, %Issue{} = issue} <- fetch_movable_issue(id),
         true <- Auth.can_move_issue?(user, issue.identifier, issue.project_slug) || {:error, :not_team_member},
         true <- IssueStage.awaiting_approval?(issue) || {:error, :not_awaiting_approval},
         definition = IssueStage.definition(issue),
         %{} = from <- Definition.stage(definition, UsageLedger.previous_node(issue.identifier)) || {:error, :unknown_origin},
         target = if(verdict == :approved, do: IssueStage.stage_definition(issue), else: from),
         :ok <- Tracker.set_stage(issue.id, target["linear_state"], target["label"], drop_labels: [approval]) do
      Store.record_review(IssueStage.flow_scope(issue) || Store.default_team(), from["id"], verdict, actor(user, opts))
      if verdict == :sent_back, do: record_move(issue.id, user, target, opts)
      labels = issue.labels |> replace_stage_label(target["label"]) |> Enum.reject(&(String.downcase(&1) == approval))
      UsageLedger.observe_issue(%{issue | state: target["linear_state"], labels: labels})
      if verdict == :approved, do: StageResult.finished(issue, target, definition)

      Orchestrator.request_refresh_async()
      ObservabilityPubSub.broadcast_update()
      :ok
    end
  end

  @doc """
  Linear labels belong to teams: a project's flow needs them in every team
  whose issues the project holds. Creates missing ones in the background.
  """
  @spec sync_stage_labels(String.t(), map()) :: :ok
  def sync_stage_labels(scope, definition) do
    labels = definition["stages"] |> Enum.map(& &1["label"]) |> Enum.filter(&is_binary/1)

    teams =
      case scope do
        "project:" <> slug -> get_in(UsageLedger.projects(), [slug, :teams]) || []
        team -> if team == Store.default_team(), do: [], else: [team]
      end

    if labels != [], do: Enum.each(teams, &sync_team_labels(&1, labels))
    :ok
  end

  @doc """
  The Linear id for an issue reference: an id as is, or an identifier
  (`PAY-12`) Symphony has seen in its flows.
  """
  @spec resolve_id(String.t()) :: String.t()
  def resolve_id(ref) when is_binary(ref) do
    ref = String.trim(ref)

    if Regex.match?(~r/^[A-Za-z0-9]+-\d+$/, ref) do
      identifier = String.upcase(ref)
      Enum.find_value(UsageLedger.snapshot().flow.issues, ref, &(&1.issue == identifier && &1.id))
    else
      ref
    end
  end

  @spec describe_error(term()) :: String.t()
  def describe_error(:controls_disabled), do: "This dashboard is read-only (server.controls: false)."
  def describe_error(:not_admin), do: "Only Linear admins can do that."
  def describe_error(:not_team_editor), do: "Only this team's members and Linear admins can change its flow."
  def describe_error(:unknown_target), do: "That stage isn't in this team's flow."
  def describe_error(:not_a_move), do: "That move isn't a connection in this team's flow."
  def describe_error(:agent_move), do: "Agents make that move. Only admins can force it."
  def describe_error(:not_awaiting_approval), do: "That issue isn't waiting for approval any more."
  def describe_error(:unknown_origin), do: "Symphony doesn't know which stage that came from. Move it from its stage instead."
  def describe_error(:invalid_team), do: "That isn't a valid team."
  def describe_error(:not_team_member), do: "You can only move issues from teams you belong to in Linear."
  def describe_error({:stage_label_not_found, label}), do: "Create the Linear label #{label} first."
  def describe_error(:signed_out), do: "Your session ended. Sign in again."
  def describe_error(:pending), do: "Your session ended. Sign in again."
  def describe_error(:issue_not_found), do: "That issue isn't in a project this Symphony manages."
  def describe_error(:state_not_found), do: "That Linear state does not exist for this team."
  def describe_error(reason), do: inspect(reason)

  # Members make the person-moved connections of their flow; admins can make
  # any connection the flow defines.
  defp allowed_move(user, issue, to) do
    definition = IssueStage.definition(issue)
    from = IssueStage.stage(issue)

    with %{} = target <- Definition.stage(definition, to) || {:error, :unknown_target},
         %{} = transition <- Enum.find(definition["transitions"], &(&1["from"] == from and &1["to"] == to)) || {:error, :not_a_move} do
      if transition["by"] == "human" or Auth.can_control?(user), do: {:ok, target}, else: {:error, :agent_move}
    end
  end

  defp actor(user, opts), do: Keyword.get(opts, :actor) || user.username || "local"

  defp sync_team_labels(team, labels), do: Task.start(fn -> log_label_sync(team, Tracker.ensure_stage_labels(team, labels)) end)

  defp log_label_sync(team, {:ok, created}), do: if(created != [], do: Logger.info("Created Linear labels team=#{team} labels=#{Enum.join(created, ",")}"))
  defp log_label_sync(team, {:error, reason}), do: Logger.warning("Linear label sync failed team=#{team} reason=#{inspect(reason)}")

  # Moves are made with Symphony's Linear key, so leave a note saying who did it.
  # The local operator at the dashboard is the person running Symphony; moves
  # from anywhere else are always noted.
  defp record_move(issue_id, user, target, opts) do
    via = Keyword.get(opts, :via)

    if user.local and is_nil(via) do
      :ok
    else
      where = if target["label"], do: "#{target["name"]} (#{target["linear_state"]} · #{IssueStage.label_prefix()}/#{target["label"]})", else: "#{target["name"]} (#{target["linear_state"]})"
      who = if user.username, do: "#{escape_markdown(user.name)} (@#{escape_markdown(user.username)})", else: escape_markdown(user.name)
      body = "**Agent Factory:** #{who} moved this to **#{escape_markdown(where)}** #{escape_markdown(via || "from the dashboard")}."

      case Tracker.create_comment(issue_id, body) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Move comment failed issue_id=#{issue_id} reason=#{inspect(reason)}")
      end
    end
  end

  # Linear display names are user-controlled; keep them from adding links or formatting.
  defp escape_markdown(text), do: String.replace(to_string(text), ~r/([\\`*_{}\[\]()#+\-.!|<>~])/, "\\\\\\1")

  defp fetch_movable_issue(id) do
    case Tracker.fetch_issue_states_by_ids([resolve_id(id)]) do
      {:ok, [%Issue{} = issue | _]} ->
        if in_configured_project?(issue), do: {:ok, issue}, else: {:error, :issue_not_found}

      {:ok, []} ->
        {:error, :issue_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Symphony may only move issues from the Linear projects it is configured for.
  defp in_configured_project?(%Issue{project_slug: slug}) do
    slugs = Enum.map(Config.linear_project_routes(), & &1.slug)
    slugs == [] or slug in slugs
  end

  defp replace_stage_label(labels, stage) do
    stage = stage && String.downcase(stage)
    prefix = IssueStage.label_prefix() <> "/"
    kept = Enum.reject(labels, &String.starts_with?(String.downcase(&1), prefix))
    if stage, do: kept ++ [prefix <> stage], else: kept
  end
end
