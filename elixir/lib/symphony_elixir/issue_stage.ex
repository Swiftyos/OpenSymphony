defmodule SymphonyElixir.IssueStage do
  @moduledoc """
  Resolves which factory stage an issue is in, using the flow it follows
  (`SymphonyElixir.Factory.Store`): its project's if the project has its own,
  otherwise its team's, otherwise the organisation default.

  A stage is identified by the issue's Linear workflow state plus an optional
  stage label from the `<prefix>/` label group (by default `factory`; Linear
  reports grouped labels as `factory/merge`, flat labels named the same work
  too). The team is the issue identifier's prefix (`PAY-12` -> `PAY`).

  An issue is dispatchable when its state is active and its stage kind is
  `queue` or `agent`. Stages of kind `human`, `parked`, or `done`, and labels in
  `tracker.paused_stages`, are never dispatched. When `tracker.require_label` is
  set (e.g. `auto-build`), issues without that label are never dispatched
  either, and removing it stops a running agent.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Factory.{Definition, Store}
  alias SymphonyElixir.Linear.Issue

  @dispatchable_kinds ["queue", "agent"]

  @doc """
  The issue's stage definition, or nil when no stage matches.
  """
  @spec stage_definition(Issue.t(), Schema.t() | nil) :: map() | nil
  def stage_definition(issue, settings \\ nil)

  def stage_definition(%Issue{state: state_name} = issue, settings) when is_binary(state_name) do
    settings = settings || Config.settings!()
    definition = definition(issue)
    prefix = label_prefix(settings)

    case labelled_stages(definition, issue, prefix) do
      [] -> Definition.stage_for(definition, state_name, [], prefix)
      [stage] -> stage
      # Two stage labels: prefer one that holds the issue still, so a human's
      # "blocked" always wins over an agent stage.
      stages -> Enum.find(stages, &(&1["kind"] not in @dispatchable_kinds)) || hd(Enum.sort_by(stages, & &1["id"]))
    end
  end

  def stage_definition(_issue, _settings), do: nil

  @spec stage(Issue.t(), Schema.t() | nil) :: String.t() | nil
  def stage(issue, settings \\ nil) do
    case stage_definition(issue, settings) do
      %{"id" => id} -> id
      _ -> nil
    end
  end

  @spec team(Issue.t() | nil) :: String.t() | nil
  def team(%Issue{identifier: identifier}) when is_binary(identifier) do
    case String.split(identifier, "-", parts: 2) do
      [key, _number] when key != "" -> key
      _ -> nil
    end
  end

  def team(_issue), do: nil

  @doc """
  The scope whose flow the issue follows: `project:<slug>`, a team key, or nil
  (the organisation default).
  """
  @spec flow_scope(Issue.t()) :: String.t() | nil
  def flow_scope(%Issue{} = issue), do: Store.scope_for(team(issue), issue.project_slug)

  @doc """
  The factory definition the issue follows.
  """
  @spec definition(Issue.t()) :: map()
  def definition(%Issue{} = issue), do: Store.get(flow_scope(issue))

  @spec warnings(Issue.t(), Schema.t() | nil) :: [String.t()]
  def warnings(issue, settings \\ nil)

  def warnings(%Issue{} = issue, settings) do
    settings = settings || Config.settings!()
    definition = definition(issue)

    case labelled_stages(definition, issue, label_prefix(settings)) do
      stages when length(stages) > 1 ->
        ["multiple stage labels (#{Enum.map_join(stages, ", ", & &1["id"])}) found; using #{stage(issue, settings)}"]

      _ ->
        []
    end
  end

  def warnings(_issue, _settings), do: []

  @doc """
  True when the issue's stage holds it still (human, parked, done, or a label in
  `tracker.paused_stages`), or it lacks `tracker.require_label`. Running agents
  on such an issue are stopped.
  """
  @spec paused?(Issue.t(), Schema.t() | nil) :: boolean()
  def paused?(issue, settings \\ nil)

  def paused?(%Issue{} = issue, settings) do
    settings = settings || Config.settings!()

    paused_label? =
      issue
      |> Issue.label_names()
      |> Enum.any?(fn label -> is_binary(label) and normalize(label) in Enum.map(paused_stages(settings), &(label_prefix(settings) <> "/" <> &1)) end)

    not opted_in?(issue, settings) or
      case stage_definition(issue, settings) do
        %{"id" => id, "kind" => kind} -> paused_label? or kind not in @dispatchable_kinds or id in paused_stages(settings)
        nil -> paused_label?
      end
  end

  def paused?(_issue, _settings), do: false

  @doc """
  True unless `tracker.require_label` is set and the issue doesn't carry it
  (case-insensitive; a grouped label such as `ai/auto-build` counts by its name).
  """
  @spec opted_in?(Issue.t(), Schema.t()) :: boolean()
  def opted_in?(%Issue{} = issue, settings) do
    case settings.tracker.require_label do
      nil ->
        true

      required ->
        required = normalize(required)

        issue
        |> Issue.label_names()
        |> Enum.any?(fn label -> is_binary(label) and (normalize(label) == required or String.ends_with?(normalize(label), "/" <> required)) end)
    end
  end

  @doc """
  True when someone paused new dispatch for this issue's stage from the
  dashboard. Unlike `paused?/2`, this does not stop running agents.
  """
  @spec dispatch_paused?(Issue.t()) :: boolean()
  def dispatch_paused?(%Issue{} = issue), do: match?(%{"paused" => true}, stage_definition(issue))
  def dispatch_paused?(_issue), do: false

  @doc """
  The key dashboard controls and per-stage caps use: `{scope, stage_id}`, where
  scope is the flow the issue follows (see `flow_scope/1`).
  """
  @spec control_stage(Issue.t()) :: {String.t() | nil, String.t()}
  def control_stage(%Issue{} = issue), do: {flow_scope(issue), stage(issue) || "todo"}

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
    Enum.any?(active_state_names(settings), &(normalize(&1) == normalized))
  end

  def active_state?(_state_name, _settings), do: false

  @doc """
  Linear states Symphony polls: `tracker.active_states` plus every state a
  saved flow (team or project) dispatches from, so adding a stage in a new
  state just works.
  """
  @spec active_state_names(Schema.t() | nil) :: [String.t()]
  def active_state_names(settings \\ nil) do
    settings = settings || Config.settings!()

    Store.scopes()
    |> Enum.flat_map(&Definition.active_states(Store.get(&1)))
    |> then(&(settings.tracker.active_states ++ &1))
    |> Enum.uniq_by(&normalize/1)
  end

  @spec label_prefix(Schema.t() | nil) :: String.t()
  def label_prefix(settings \\ nil) do
    settings = settings || Config.settings!()
    normalize(settings.tracker.stage_label_prefix || "factory")
  end

  defp labelled_stages(definition, %Issue{state: state_name} = issue, prefix) do
    issue
    |> Issue.label_names()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize/1)
    |> Enum.filter(&String.starts_with?(&1, prefix <> "/"))
    |> Enum.uniq()
    |> Enum.flat_map(fn label ->
      case Definition.stage_for(definition, state_name, [label], prefix) do
        %{"label" => stage_label} = stage when is_binary(stage_label) -> [stage]
        _ -> []
      end
    end)
    |> Enum.uniq_by(& &1["id"])
  end

  defp paused_stages(settings) do
    settings.tracker.paused_stages
    |> List.wrap()
    |> Enum.map(&normalize/1)
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(value), do: value |> to_string() |> normalize()
end
