defmodule SymphonyElixir.IssueStage do
  @moduledoc """
  Resolves the factory stage of an issue from its Linear state plus stage labels.

  Teams keep Linear's default workflow states (`Todo`, `In Progress`, `In Review`,
  `Done`, ...) and express sub-stages with labels from a single label group, by
  default `factory`. Linear reports grouped labels as `<group>/<child>`, so a
  `factory` group with a `merge` child arrives as `factory/merge`. Flat labels
  named `factory/merge` resolve identically.

  An issue is dispatchable when its state is active and its stage is not paused.
  """

  alias SymphonyElixir.{Config, FactoryControls}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @default_stage "implement"

  @spec stage(Issue.t(), Schema.t() | nil) :: String.t() | nil
  def stage(issue, settings \\ nil)

  def stage(%Issue{} = issue, settings) do
    settings = settings || Config.settings!()

    case stage_labels(issue, settings) do
      [] -> default_stage(issue, settings)
      [stage] -> stage
      stages -> conflicting_stage(stages, settings)
    end
  end

  def stage(_issue, _settings), do: nil

  @spec warnings(Issue.t(), Schema.t() | nil) :: [String.t()]
  def warnings(issue, settings \\ nil)

  def warnings(%Issue{} = issue, settings) do
    settings = settings || Config.settings!()

    case stage_labels(issue, settings) do
      stages when length(stages) > 1 ->
        ["multiple stage labels (#{Enum.join(stages, ", ")}) found; using #{conflicting_stage(stages, settings)}"]

      _ ->
        []
    end
  end

  def warnings(_issue, _settings), do: []

  @spec paused?(Issue.t(), Schema.t() | nil) :: boolean()
  def paused?(issue, settings \\ nil)

  def paused?(%Issue{} = issue, settings) do
    settings = settings || Config.settings!()
    stage(issue, settings) in paused_stages(settings)
  end

  def paused?(_issue, _settings), do: false

  @doc """
  True when an operator paused new dispatch for this issue's stage from the
  dashboard. Unlike a paused stage label, this does not stop running agents.
  """
  @spec dispatch_paused?(Issue.t()) :: boolean()
  def dispatch_paused?(%Issue{} = issue), do: FactoryControls.paused?(control_stage(issue))
  def dispatch_paused?(_issue), do: false

  @doc """
  The stage key used for dashboard controls; `Todo` issues map to `todo`.
  """
  @spec control_stage(Issue.t()) :: String.t() | nil
  def control_stage(%Issue{} = issue), do: stage(issue) || "todo"

  @spec active?(Issue.t(), Schema.t() | nil) :: boolean()
  def active?(issue, settings \\ nil)

  def active?(%Issue{state: state_name} = issue, settings) when is_binary(state_name) do
    settings = settings || Config.settings!()
    active_state?(state_name, settings) and not paused?(issue, settings)
  end

  def active?(_issue, _settings), do: false

  @spec active_state?(String.t() | nil, Schema.t() | nil) :: boolean()
  def active_state?(state_name, settings \\ nil)

  def active_state?(state_name, settings) when is_binary(state_name) do
    settings = settings || Config.settings!()
    normalized = normalize(state_name)
    Enum.any?(settings.tracker.active_states, &(normalize(&1) == normalized))
  end

  def active_state?(_state_name, _settings), do: false

  @spec label_prefix(Schema.t() | nil) :: String.t()
  def label_prefix(settings \\ nil) do
    settings = settings || Config.settings!()
    normalize(settings.tracker.stage_label_prefix || "factory")
  end

  defp stage_labels(%Issue{} = issue, settings) do
    prefix = label_prefix(settings) <> "/"

    issue
    |> Issue.label_names()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize/1)
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # `Todo` has no stage until the agent picks it up; every other active state
  # without a stage label is treated as normal implementation work.
  defp default_stage(%Issue{state: state_name}, settings) when is_binary(state_name) do
    cond do
      normalize(state_name) == "todo" -> nil
      active_state?(state_name, settings) -> @default_stage
      true -> nil
    end
  end

  defp default_stage(_issue, _settings), do: nil

  # A paused label always wins so a human can park an issue regardless of other
  # labels; otherwise pick deterministically so dispatch is stable.
  defp conflicting_stage(stages, settings) do
    paused = paused_stages(settings)
    Enum.find(stages, &(&1 in paused)) || stages |> Enum.sort() |> List.first()
  end

  defp paused_stages(settings) do
    settings.tracker.paused_stages
    |> List.wrap()
    |> Enum.map(&normalize/1)
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(value), do: value |> to_string() |> normalize()
end
