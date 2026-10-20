defmodule SymphonyElixir.Factory.StagePrompt do
  @moduledoc """
  Renders the "your current stage" part of an agent's prompt from the issue's
  flow: the stage's instructions, how stages hand work to each other, and every
  move allowed from it, with the exact Linear state and stage label for each.

  Stages hand off through two channels: the Linear issue (each stage reads the
  earlier stages' comments) and the issue's git branch (`symphony/<ID>`),
  which carries the code.

  Agents never change the issue's state or labels. They finish by writing
  `.symphony/result.json` with their move and summary, and Symphony checks it,
  posts the summary as the stage's comment, and moves the issue
  (`SymphonyElixir.StageResult`).
  """

  alias SymphonyElixir.Factory.Definition
  alias SymphonyElixir.IssueStage
  alias SymphonyElixir.Linear.Issue

  @spec render(Issue.t()) :: String.t()
  def render(%Issue{} = issue) do
    case IssueStage.stage_definition(issue) do
      %{} = stage -> render_stage(issue, stage)
      _ -> ""
    end
  end

  def render(_issue), do: ""

  @doc """
  Template variables for the workflow prompt (`{{ stage.name }}`, ...).
  """
  @spec variables(Issue.t()) :: map()
  def variables(%Issue{} = issue) do
    case IssueStage.stage_definition(issue) do
      %{} = stage ->
        %{"id" => stage["id"], "name" => stage["name"], "kind" => stage["kind"], "instructions" => stage["instructions"], "prompt" => render(issue)}

      nil ->
        %{"id" => nil, "name" => nil, "kind" => nil, "instructions" => nil, "prompt" => ""}
    end
  end

  def variables(_issue), do: variables(%Issue{})

  defp render_stage(issue, stage) do
    definition = IssueStage.definition(issue)
    prefix = IssueStage.label_prefix()

    [
      "## Your current stage: #{stage["name"]}",
      "",
      blank_or(stage["instructions"], "Follow the workflow for this stage."),
      "",
      skill_section(stage),
      handoff_section(issue, stage),
      "### Allowed moves from here",
      "",
      moves(definition, stage, prefix),
      "",
      move_rule(definition, stage, prefix)
    ]
    |> Enum.join("\n")
  end

  defp handoff_section(issue, _stage) do
    branch = "symphony/#{issue.identifier}"

    """
    ### Hand-off between stages

    - **Read first.** Earlier stages post their output as comments on this Linear issue, each headed
      `## <stage name>` (the newest one wins when a stage ran more than once). Read them all before you
      start, and build on them instead of redoing their work.
    - **Code travels on the branch `#{branch}`.** If it exists on `origin`, check it out and start from it.
      Commit and push your changes to it before you finish.
    - **Your summary is the hand-off.** It becomes this stage's comment on the issue: what you did, what
      you found or decided, and what the next stage needs (file paths, commands, results, open
      questions). The next stage reads only the issue and the branch, so put everything it needs there.
    """
  end

  defp move_rule(definition, stage, _prefix) do
    checks =
      case stage["checks"] || [] do
        [] -> ""
        list -> "\n\nBefore it moves the issue, Symphony runs these checks in your workspace; all must pass:\n" <> Enum.map_join(list, "\n", &("- `" <> &1 <> "`"))
      end

    approval =
      if Definition.requires_approval?(definition, stage),
        do: "\n\nA person approves the move before the next stage starts; say clearly in your summary why you chose it.",
        else: ""

    """
    ### Finishing this stage

    Don't change the issue's state or labels, and don't post the stage comment yourself: Symphony does both.
    When your work is done, write `.symphony/result.json` in the workspace root:

        {"move": "<one of the stage ids above that you can move to>", "summary": "<markdown hand-off>"}

    Symphony checks the move is allowed, posts your summary on the issue as `## #{stage["name"]}`, and moves the
    issue. If it can't, it tells you why and you fix it.#{checks}#{approval}
    """
  end

  defp moves(definition, stage, _prefix) do
    case Definition.transitions_from(definition, stage["id"]) do
      [] ->
        "- None. This stage ends the flow."

      transitions ->
        Enum.map_join(transitions, "\n", &move_line(definition, &1))
    end
  end

  defp move_line(definition, transition) do
    target = Definition.stage(definition, transition["to"])
    criteria = blank_or(transition["criteria"], "when the work for this stage is done")

    case transition["by"] do
      "agent" -> "- `#{target["id"]}` → **#{target["name"]}**: #{criteria}."
      _ -> "- **#{target["name"]}** (a person moves it, not you): #{criteria}."
    end
  end

  defp skill_section(%{"skill" => %{"path" => path, "content" => content}}),
    do: "### Skill for this stage (#{path})\n\n#{String.trim(content)}\n"

  defp skill_section(_stage), do: ""

  defp blank_or(value, fallback) when is_binary(value), do: if(String.trim(value) == "", do: fallback, else: String.trim(value))
  defp blank_or(_value, fallback), do: fallback
end
