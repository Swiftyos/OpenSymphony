defmodule SymphonyElixir.Factory.StagePrompt do
  @moduledoc """
  Renders the "your current stage" part of an agent's prompt from the issue's
  team factory: the stage's instructions and every move allowed from it, with
  the exact Linear state and stage label to apply for each.
  """

  alias SymphonyElixir.Factory.{Definition, Store}
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
    definition = Store.get(IssueStage.team(issue))
    prefix = IssueStage.label_prefix()

    [
      "## Your current stage: #{stage["name"]}",
      "",
      blank_or(stage["instructions"], "Follow the workflow for this stage."),
      "",
      skill_section(stage),
      "### Allowed moves from here",
      "",
      moves(definition, stage, prefix),
      "",
      "Move the issue by setting its Linear state and `#{prefix}/*` stage label exactly as listed. " <>
        "Only make moves marked for agents; moves marked for humans are theirs to make. " <>
        "If none of these fit, record why in the workpad and stop."
    ]
    |> Enum.join("\n")
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
