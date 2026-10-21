defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with the configured agent backend.
  """

  require Logger

  alias SymphonyElixir.AgentRoute
  alias SymphonyElixir.AppServer
  alias SymphonyElixir.ClaudeCode.Tooling, as: ClaudeCodeTooling
  alias SymphonyElixir.Codex.AppServer, as: CodexAppServer
  alias SymphonyElixir.Factory.Definition
  alias SymphonyElixir.IssueConfig
  alias SymphonyElixir.IssueStage
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.OpenCode.Tooling
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.RunHost
  alias SymphonyElixir.Sandbox
  alias SymphonyElixir.StageResult
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Workspace

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, agent_update_recipient \\ nil, opts \\ []) do
    issue_config = Keyword.get(opts, :issue_config) || resolve_issue_config!(issue)
    route = Keyword.get(opts, :route) || AgentRoute.resolve(issue, issue_config.settings)
    account = Keyword.get(opts, :account)
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), issue_config.settings.worker.ssh_hosts)

    Logger.info(
      "Starting agent run for #{issue_context(issue)} backend=#{route.backend} effort=#{route.effort || "default"} worker_host=#{worker_host_for_log(worker_host)} account=#{account_label(account)}"
    )

    # The run talks to the controller only through its host; in-process unless
    # a run host is injected (tests, and later the remote runner).
    host = Keyword.get(opts, :run_host) || RunHost.local(agent_update_recipient)

    run_opts =
      opts
      |> Keyword.put(:route, route)
      |> Keyword.put(:issue_config, issue_config)
      |> Keyword.put(:run_host, host)

    case run_on_worker_host(issue, host, run_opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        formatted_reason = format_run_failure(reason)
        Logger.error("Agent run failed for #{issue_context(issue)}: #{formatted_reason}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{formatted_reason}"
    end
  end

  defp run_on_worker_host(issue, host, opts, worker_host) do
    route = Keyword.fetch!(opts, :route)
    issue_config = Keyword.fetch!(opts, :issue_config)
    account = Keyword.get(opts, :account)

    Logger.info(
      "Starting worker attempt for #{issue_context(issue)} backend=#{route.backend} effort=#{route.effort || "default"} worker_host=#{worker_host_for_log(worker_host)} account=#{account_label(account)}"
    )

    with :ok <- Sandbox.validate_run(route.backend, worker_host, issue_config.settings),
         {:ok, workspace} <- Workspace.create_for_issue(issue, worker_host, settings: issue_config.settings) do
      run_in_workspace(workspace, issue, host, opts, worker_host, route, issue_config)
    end
  end

  defp run_in_workspace(workspace, issue, host, opts, worker_host, route, issue_config) do
    RunHost.runtime_info(host, issue, worker_host, workspace)

    try do
      with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host, settings: issue_config.settings),
           :ok <- prepare_workspace_for_backend(workspace, worker_host, route.backend, issue_config) do
        run_backend_turns(workspace, issue, host, opts, worker_host, route)
      end
    after
      Sandbox.reap(workspace, issue_config.settings)
      Workspace.run_after_run_hook(workspace, issue, worker_host, settings: issue_config.settings)
    end
  end

  defp run_backend_turns(workspace, issue, host, opts, worker_host, route) do
    # Lets dashboard messages (SymphonyElixir.AgentInbox) find this run.
    RunHost.inbox_register(host, issue, route.backend)

    try do
      case route.backend do
        "codex" -> run_codex_turns(workspace, issue, host, opts, worker_host, route)
        _ -> run_agent_turns(workspace, issue, host, opts, worker_host, route)
      end
    after
      RunHost.inbox_unregister(host, issue.identifier)
    end
  end

  defp codex_message_handler(host, issue) do
    fn message -> RunHost.agent_update(host, issue, "codex", message) end
  end

  defp agent_message_handler(host, issue, backend) do
    fn message -> RunHost.agent_update(host, issue, backend, message) end
  end

  defp run_codex_turns(workspace, issue, host, opts, worker_host, route) do
    issue_config = Keyword.fetch!(opts, :issue_config)
    max_turns = Keyword.get(opts, :max_turns, issue_config.settings.agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    StageResult.exclude_from_git(workspace)
    issue = pick_up(issue)

    resume = resumable_session(host, issue, workspace, "codex")

    case CodexAppServer.start_session(workspace,
           worker_host: worker_host,
           effort: AgentRoute.codex_effort(route.effort),
           issue: issue,
           account: Keyword.get(opts, :account),
           resume_thread_id: resume && resume["thread_id"]
         ) do
      {:ok, session} ->
        remember_session(host, issue, workspace, "codex", %{"thread_id" => session.thread_id})
        opts = Keyword.put(opts, :resumed, session.resumed)

        try do
          do_run_codex_turns(session, workspace, issue, host, opts, issue_state_fetcher, 1, max_turns)
        after
          CodexAppServer.stop_session(session)
          RunHost.session_delete(host, issue.id)
        end

      {:error, _reason} = error ->
        RunHost.session_delete(host, issue.id)
        error
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, host, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = turn_prompt(host, issue, build_codex_turn_prompt(issue, opts, turn_number, max_turns), turn_number, "codex")

    with {:ok, turn_session} <-
           CodexAppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(host, issue),
             turn_number: turn_number,
             run_host: host
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case after_turn(host, issue, workspace, issue_state_fetcher) do
        {:retry, feedback} when turn_number < max_turns ->
          next_opts = Keyword.put(opts, :result_feedback, feedback)

          do_run_codex_turns(
            app_session,
            workspace,
            issue,
            host,
            next_opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:retry, _feedback} ->
          :ok

        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            host,
            Keyword.delete(opts, :result_feedback),
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          last_codex_turn(
            app_session,
            workspace,
            refreshed_issue,
            host,
            opts,
            issue_state_fetcher,
            turn_number,
            max_turns
          )

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_agent_turns(workspace, issue, host, opts, worker_host, route) do
    issue_config = Keyword.fetch!(opts, :issue_config)
    max_turns = Keyword.get(opts, :max_turns, issue_config.settings.agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    session_opts = [
      worker_host: worker_host,
      backend: route.backend,
      effort: AgentRoute.claude_effort(route.effort),
      variant: AgentRoute.opencode_variant(route.effort),
      issue: issue,
      account: Keyword.get(opts, :account)
    ]

    StageResult.exclude_from_git(workspace)
    issue = pick_up(issue)

    resume = resumable_session(host, issue, workspace, route.backend)

    case AppServer.start_session(workspace, Keyword.put(session_opts, :resume_session_id, resume && resume["session_id"])) do
      {:ok, session} ->
        remember_session(host, issue, workspace, route.backend, %{"session_id" => session[:session_id]})
        opts = opts |> Keyword.put(:backend, route.backend) |> Keyword.put(:resumed, session[:resumed] == true)

        try do
          do_run_agent_turns(session, workspace, issue, host, opts, issue_state_fetcher, 1, max_turns)
        after
          AppServer.stop_session(session, backend: route.backend)
          RunHost.session_delete(host, issue.id)
        end

      {:error, _reason} = error ->
        RunHost.session_delete(host, issue.id)
        error
    end
  end

  # A session recorded by a run that a restart cut off, if it is for this same
  # stage, backend and workspace; a record that no longer matches is dropped.
  defp resumable_session(host, %Issue{id: issue_id} = issue, workspace, backend) do
    stage = IssueStage.stage(issue)

    case RunHost.session_get(host, issue_id) do
      %{"backend" => ^backend, "stage" => ^stage, "workspace" => ^workspace} = record when is_binary(stage) ->
        Logger.info("Resuming interrupted #{backend} session for #{issue_context(issue)} stage=#{stage}")
        record

      nil ->
        nil

      _stale ->
        RunHost.session_delete(host, issue_id)
        nil
    end
  end

  defp resumable_session(_host, _issue, _workspace, _backend), do: nil

  defp remember_session(host, %Issue{id: issue_id} = issue, workspace, backend, ids) do
    record = %{"backend" => backend, "stage" => IssueStage.stage(issue), "workspace" => workspace, "identifier" => issue.identifier}
    RunHost.session_put(host, issue_id, Map.merge(record, ids))
  end

  defp do_run_agent_turns(
         app_session,
         workspace,
         issue,
         host,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    backend = Keyword.get(opts, :backend)

    prompt =
      turn_prompt(host, issue, build_agent_turn_prompt(issue, opts, turn_number, max_turns), turn_number, backend)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             backend: Keyword.get(opts, :backend),
             on_message: agent_message_handler(host, issue, backend),
             run_host: host
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case after_turn(host, issue, workspace, issue_state_fetcher) do
        {:retry, feedback} when turn_number < max_turns ->
          next_opts = Keyword.put(opts, :result_feedback, feedback)

          do_run_agent_turns(
            app_session,
            workspace,
            issue,
            host,
            next_opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:retry, _feedback} ->
          :ok

        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_agent_turns(
            app_session,
            workspace,
            refreshed_issue,
            host,
            Keyword.delete(opts, :result_feedback),
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          last_agent_turn(
            app_session,
            workspace,
            refreshed_issue,
            host,
            opts,
            issue_state_fetcher,
            turn_number,
            max_turns
          )

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_codex_turn_prompt(issue, opts, turn_number, max_turns), do: build_agent_turn_prompt(issue, opts, turn_number, max_turns)

  # The conversation so far is already in the resumed session, so the stage prompt isn't sent again.
  defp resumed_prompt do
    "Symphony restarted while you were working on this stage. Your conversation so far is above. " <>
      "Continue from where you left off: don't redo work you've finished, and finish the stage as its instructions describe."
  end

  # Every turn starts with a transcript marker; dashboard messages that are
  # still queued are delivered here, ahead of the turn's own prompt.
  defp turn_prompt(host, issue, prompt, turn_number, backend) do
    RunHost.turn_started(host, issue.identifier, %{turn: turn_number, stage: IssueStage.stage(issue), backend: backend})
    RunHost.inbox_prompt_section(host, RunHost.inbox_take_queued(host, issue.identifier)) <> prompt
  end

  # At agent.max_turns the run hands back to the orchestrator, which dispatches
  # the issue again. If people sent messages during the last turn, run one more
  # turn (once per run) so the agent answers them now.
  defp last_codex_turn(app_session, workspace, issue, host, opts, fetcher, turn, max_turns) do
    case bonus_turn_opts(host, issue, opts) do
      nil -> :ok
      next -> do_run_codex_turns(app_session, workspace, issue, host, next, fetcher, turn + 1, max_turns + 1)
    end
  end

  defp last_agent_turn(app_session, workspace, issue, host, opts, fetcher, turn, max_turns) do
    case bonus_turn_opts(host, issue, opts) do
      nil -> :ok
      next -> do_run_agent_turns(app_session, workspace, issue, host, next, fetcher, turn + 1, max_turns + 1)
    end
  end

  defp bonus_turn_opts(host, issue, opts) do
    if Keyword.get(opts, :inbox_bonus_turn) != true and RunHost.inbox_queued?(host, issue.identifier) do
      Logger.info("Running one more turn for #{issue_context(issue)} to deliver dashboard messages")
      opts |> Keyword.delete(:result_feedback) |> Keyword.put(:inbox_bonus_turn, true)
    else
      Logger.info("Reached agent.max_turns for #{issue_context(issue)} with issue still active; returning control to orchestrator")
      nil
    end
  end

  # Symphony moves the issue: a result file the agent wrote decides the move;
  # without one, the agent keeps working while the issue stays in its stage.
  defp after_turn(host, issue, workspace, issue_state_fetcher) do
    case StageResult.process(issue, workspace) do
      {:moved, target} ->
        RunHost.transcript_note(host, issue.identifier, "Agent Factory moved the issue to #{target["name"]}.")
        {:done, issue}

      {:rejected, feedback} ->
        RunHost.transcript_note(host, issue.identifier, "Agent Factory didn't accept the result: " <> feedback)
        {:retry, feedback}

      :none ->
        issue |> continue_with_issue?(issue_state_fetcher) |> hold_unapproved_move(issue)
    end
  end

  # Agents are told not to move issues, but if one does, a move out of a stage
  # that needs approval is still held for a person.
  defp hold_unapproved_move({:done, %Issue{} = moved} = outcome, issue) do
    definition = IssueStage.definition(issue)
    from = IssueStage.stage_definition(issue)
    to = IssueStage.stage_definition(moved)

    moved_out? = from && to && from["id"] != to["id"]

    if moved_out? && Definition.requires_approval?(definition, from) && not IssueStage.awaiting_approval?(moved) do
      Logger.warning("Agent moved #{issue_context(moved)} from=#{from["id"]} to=#{to["id"]} itself; holding it for approval")
      Tracker.set_stage(moved.id, moved.state, to["label"], add_labels: [IssueStage.approval_label()])
      note = "_Agent Factory: the agent moved this from #{from["name"]} to #{to["name"]} itself. Held for a person to approve._"
      Tracker.create_comment(moved.id, note)
    end

    outcome
  end

  defp hold_unapproved_move(outcome, _issue), do: outcome

  # An issue waiting in a queue stage with one agent connection out (Todo ->
  # Research) is picked up by Symphony itself, so no agent turn is spent on it.
  defp pick_up(%Issue{} = issue) do
    definition = IssueStage.definition(issue)

    with %{"kind" => "queue", "id" => from} <- IssueStage.stage_definition(issue),
         [%{"to" => to}] <- for(t <- Definition.transitions_from(definition, from), t["by"] == "agent", do: t),
         %{} = target <- Definition.stage(definition, to),
         :ok <- Tracker.set_stage(issue.id, target["linear_state"], target["label"]) do
      Logger.info("Symphony picked up #{issue_context(issue)} from=#{from} to=#{to}")
      prefix = IssueStage.label_prefix() <> "/"
      labels = Enum.reject(issue.labels, &String.starts_with?(String.downcase(&1), prefix))
      %{issue | state: target["linear_state"], labels: if(target["label"], do: labels ++ [prefix <> target["label"]], else: labels)}
    else
      _ -> issue
    end
  end

  defp build_agent_turn_prompt(issue, opts, 1, _max_turns) do
    if Keyword.get(opts, :resumed), do: resumed_prompt(), else: PromptBuilder.build_prompt(issue, opts)
  end

  defp build_agent_turn_prompt(issue, opts, turn_number, max_turns) do
    case Keyword.get(opts, :result_feedback) do
      nil -> continuation_prompt(issue, turn_number, max_turns)
      feedback -> "Symphony didn't accept your stage result:\n\n#{feedback}\n\nFix this, then write `.symphony/result.json` again."
    end
  end

  defp continuation_prompt(issue, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous agent turn completed normally, but the issue is still in this stage.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Current Linear state: #{issue.state}; factory stage: #{IssueStage.stage(issue) || "none"}.
    - When this stage's work is done, write `.symphony/result.json` with your move and summary (see "Your current stage"); Symphony moves the issue.
    - Resume from the current workspace state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining work and do not end the turn while the issue stays in this stage unless you are truly blocked.
    """
  end

  defp prepare_workspace_for_backend(workspace, worker_host, backend, issue_config) do
    case backend do
      "opencode" -> Tooling.bootstrap_workspace(workspace)
      "claude" -> ClaudeCodeTooling.bootstrap_workspace(workspace, worker_host, timeout_ms: issue_config.settings.hooks.timeout_ms)
      _ -> :ok
    end
  end

  defp resolve_issue_config!(issue) do
    case IssueConfig.resolve(issue) do
      {:ok, issue_config} ->
        issue_config

      {:error, reason} ->
        raise ArgumentError, message: "Invalid issue config for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        cond do
          not IssueStage.active?(refreshed_issue) ->
            {:done, refreshed_issue}

          stage_changed?(IssueStage.stage_definition(issue), IssueStage.stage_definition(refreshed_issue)) ->
            # A new stage (for example implement -> merge) needs its own first-turn
            # prompt, so hand back to the orchestrator for a fresh dispatch.
            Logger.info("Stage changed for #{issue_context(refreshed_issue)} from=#{IssueStage.stage(issue) || "none"} to=#{IssueStage.stage(refreshed_issue)}; returning control to orchestrator")

            {:done, refreshed_issue}

          true ->
            {:continue, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  # Leaving a queue stage (Todo -> Implement) is the agent picking the work up,
  # not a new stage that needs a fresh prompt.
  defp stage_changed?(%{"kind" => "queue"}, _current_stage), do: false
  defp stage_changed?(previous, current), do: stage_id(previous) != stage_id(current)

  defp stage_id(%{"id" => id}), do: id
  defp stage_id(_stage), do: nil

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp account_label(nil), do: "host-auth"

  defp account_label(%{backend: backend, id: id}) when is_binary(backend) and is_binary(id) do
    "#{backend}:#{id}"
  end

  defp account_label(account), do: inspect(account, limit: 4)

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp format_run_failure(%{message: message} = reason) when is_binary(message) do
    case Map.drop(reason, [:message]) do
      details when map_size(details) == 0 ->
        message

      details ->
        "#{message} details=#{inspect(details, limit: 10)}"
    end
  end

  defp format_run_failure(%{"message" => message} = reason) when is_binary(message) do
    case Map.drop(reason, ["message"]) do
      details when map_size(details) == 0 ->
        message

      details ->
        "#{message} details=#{inspect(details, limit: 10)}"
    end
  end

  defp format_run_failure(reason), do: inspect(reason, limit: :infinity, printable_limit: :infinity)
end
