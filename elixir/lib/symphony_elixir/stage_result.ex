defmodule SymphonyElixir.StageResult do
  @moduledoc """
  Symphony, not the agent, moves issues through the flow.

  An agent finishes its stage by writing `.symphony/result.json` in its
  workspace:

      {"move": "<stage id>", "summary": "<what it did, found, and hands on>"}

  After every agent turn Symphony looks for that file and:

    1. checks `move` is an agent connection out of the issue's current stage
       and `summary` isn't empty
    2. runs the stage's `checks` (shell commands) in the workspace; all must
       exit 0
    3. posts the summary on the issue as the stage's comment
       (`## <stage name>`), then sets the target stage's Linear state and stage
       label, adding the approval label when a person must approve the move

  When something is wrong the file is set aside and the agent is told exactly
  what to fix, then keeps working. `.symphony/` is kept out of git.
  """

  require Logger

  alias SymphonyElixir.Factory.Definition
  alias SymphonyElixir.{IssueStage, Tracker}
  alias SymphonyElixir.Linear.Issue

  @dir ".symphony"
  @file_name "result.json"
  @max_summary 60_000
  @check_timeout_ms 20 * 60_000
  @max_check_output 4_000

  @type outcome :: :none | {:moved, map()} | {:rejected, String.t()}

  @doc """
  The result file's path in a workspace.
  """
  @spec path(Path.t()) :: Path.t()
  def path(workspace), do: Path.join([workspace, @dir, @file_name])

  @doc """
  Keeps `.symphony/` out of git in a workspace clone.
  """
  @spec exclude_from_git(Path.t()) :: :ok
  def exclude_from_git(workspace) do
    exclude = Path.join([workspace, ".git", "info", "exclude"])

    with true <- File.dir?(Path.dirname(exclude)),
         current = if(File.exists?(exclude), do: File.read!(exclude), else: ""),
         false <- String.contains?(current, "/#{@dir}/") do
      File.write!(exclude, String.trim_trailing(current) <> "\n/#{@dir}/\n")
    end

    :ok
  end

  @doc """
  Handles the result file, if the agent wrote one, for `issue` (as it was when
  the turn started). Returns `:none` when there is no file, `{:moved, target}`
  after moving the issue, or `{:rejected, feedback}` for the agent.
  """
  @spec process(Issue.t(), Path.t(), keyword()) :: outcome()
  def process(%Issue{} = issue, workspace, opts \\ []) do
    file = path(workspace)

    case File.read(file) do
      {:error, :enoent} ->
        :none

      {:ok, body} ->
        outcome =
          with {:ok, result} <- decode(body),
               {:ok, stage, target, definition} <- allowed_move(issue, result["move"]),
               :ok <- run_checks(stage, workspace, opts) do
            move(issue, stage, target, definition, result["summary"])
          end

        set_aside(file, outcome)
        outcome

      {:error, reason} ->
        {:rejected, "Symphony couldn't read #{@dir}/#{@file_name}: #{inspect(reason)}."}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"move" => move, "summary" => summary}} when is_binary(move) and is_binary(summary) ->
        if String.trim(summary) == "",
          do: {:rejected, "The summary in #{@dir}/#{@file_name} is empty. Say what you did, what you found, and what the next stage needs."},
          else: {:ok, %{"move" => String.trim(move), "summary" => String.slice(summary, 0, @max_summary)}}

      _ ->
        {:rejected, ~s(#{@dir}/#{@file_name} must be JSON like {"move": "<stage id>", "summary": "<markdown>"}.)}
    end
  end

  defp allowed_move(issue, move) do
    definition = IssueStage.definition(issue)
    stage = IssueStage.stage_definition(issue)
    moves = if stage, do: for(t <- Definition.transitions_from(definition, stage["id"]), t["by"] == "agent", do: t["to"]), else: []

    cond do
      is_nil(stage) ->
        {:rejected, "The issue isn't in a stage of its flow, so Symphony can't move it."}

      move in moves ->
        {:ok, stage, Definition.stage(definition, move), definition}

      true ->
        {:rejected, "\"#{move}\" isn't a move you can make from #{stage["name"]}. Pick one of: #{Enum.join(moves, ", ")}."}
    end
  end

  defp run_checks(stage, workspace, opts) do
    timeout_ms = Keyword.get(opts, :check_timeout_ms, @check_timeout_ms)
    runner = Keyword.get(opts, :check_runner, &run_check(&1, &2, timeout_ms))

    failures =
      for check <- stage["checks"] || [], {status, output} = runner.(check, workspace), status != 0 do
        "`#{check}` exited #{status}:\n#{output |> String.slice(-@max_check_output, @max_check_output)}"
      end

    case failures do
      [] -> :ok
      _ -> {:rejected, "Symphony ran this stage's checks and some failed. Fix them, then write the result again.\n\n" <> Enum.join(failures, "\n\n")}
    end
  end

  defp run_check(command, workspace, timeout_ms) do
    task = Task.async(fn -> System.cmd("bash", ["-lc", command], cd: workspace, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} -> {status, output}
      _ -> {124, "timed out after #{div(timeout_ms, 1000)} seconds"}
    end
  end

  defp move(issue, stage, target, definition, summary) do
    approval = Definition.requires_approval?(definition, stage)
    add_labels = if approval, do: [IssueStage.approval_label()], else: []
    note = if approval, do: "_Moved to #{target["name"]} by Symphony; waiting for a person to approve._", else: "_Moved to #{target["name"]} by Symphony._"

    with :ok <- Tracker.create_comment(issue.id, "## #{stage["name"]}\n\n#{String.trim(summary)}\n\n#{note}"),
         :ok <- Tracker.set_stage(issue.id, target["linear_state"], target["label"], add_labels: add_labels) do
      Logger.info("Symphony moved #{issue.identifier} from=#{stage["id"]} to=#{target["id"]} approval=#{approval}")
      {:moved, target}
    else
      {:error, reason} ->
        Logger.warning("Symphony couldn't move #{issue.identifier} to #{target["id"]}: #{inspect(reason)}")
        {:rejected, "Symphony accepted your result but couldn't update Linear (#{inspect(reason)}). Write the result file again to retry."}
    end
  end

  # Keep a record of every result; a rejected one must not be processed again.
  defp set_aside(file, outcome) do
    tag = if match?({:moved, _}, outcome), do: "accepted", else: "rejected"
    stamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    File.rename(file, Path.join(Path.dirname(file), "#{tag}-#{stamp}-#{System.unique_integer([:positive])}.json"))
  end
end
