defmodule SymphonyElixir.Factory.StagePrompt do
  @moduledoc """
  Renders the "your current stage" part of an agent's prompt from the issue's
  flow: the stage's instructions, how stages hand work to each other, and every
  move allowed from it, with the exact Linear state and stage label for each.

  Stages hand off through two channels: the Linear issue (each stage reads the
  earlier stages' comments and posts its own, headed with its name) and the
  issue's git branch (`symphony/<ID>`), which carries the code.
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

  defp handoff_section(issue, stage) do
    branch = "symphony/#{issue.identifier}"

    """
    ### Hand-off between stages

    - **Read first.** Earlier stages post their output as comments on this Linear issue, each headed
      `## <stage name>` (the newest one wins when a stage ran more than once). Read them all before you
      start, and build on them instead of redoing their work.
    - **Code travels on the branch `#{branch}`.** If it exists on `origin`, check it out and start from it.
      Commit and push your changes to it before you move the issue.
    - **Post your output.** When your work is done, add one new comment headed `## #{stage["name"]}`: what
      you did, what you found or decided, and what the next stage needs (file paths, commands, results,
      open questions). The next stage reads only the issue and the branch, so put everything it needs there.
    """
  end

  defp move_rule(definition, stage, prefix) do
    base =
      "Move the issue by setting its Linear state and `#{prefix}/*` stage label exactly as listed. " <>
        "Only make moves marked for agents; moves marked for humans are theirs to make. " <>
        "If none of these fit, record why in your stage comment and stop."

    if Definition.requires_approval?(definition, stage) do
      base <>
        "\n\n**A person approves your move from this stage.** Make the move as usual, then also add the " <>
        "`#{IssueStage.approval_label()}` label to the issue. Say in your stage comment which move you made and why. " <>
        "The issue waits there until a person approves it or sends it back to this stage."
    else
      base
    end
  end

  defp moves(definition, stage, prefix) do
    case Definition.transitions_from(definition, stage["id"]) do
      [] ->
        "- None. This stage ends the flow."

      transitions ->
        Enum.map_join(transitions, "\n", &move_line(definition, &1, prefix))
    end
  end

  defp move_line(definition, transition, prefix) do
    target = Definition.stage(definition, transition["to"])
    who = if transition["by"] == "agent", do: "you", else: "a human"
    criteria = blank_or(transition["criteria"], "when the work for this stage is done")
    "- **#{target["name"]}** (#{who}): #{criteria}. Set state `#{target["linear_state"]}`#{label_text(target, prefix)}."
  end

  defp skill_section(%{"skill" => %{"path" => path, "content" => content}}),
    do: "### Skill for this stage (#{path})\n\n#{String.trim(content)}\n"

  defp skill_section(_stage), do: ""

  defp label_text(%{"label" => label}, prefix) when is_binary(label), do: " and label `#{prefix}/#{label}` (remove other `#{prefix}/*` labels)"
  defp label_text(_target, prefix), do: " and remove any `#{prefix}/*` label"

  defp blank_or(value, fallback) when is_binary(value), do: if(String.trim(value) == "", do: fallback, else: String.trim(value))
  defp blank_or(_value, fallback), do: fallback
end
