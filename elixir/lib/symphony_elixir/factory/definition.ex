defmodule SymphonyElixir.Factory.Definition do
  @moduledoc """
  A team's agent factory: the stages work moves through and how they connect.

  A stage is identified in Linear by a workflow state plus, optionally, a
  `<prefix>/<label>` stage label, so many stages can share one Linear state
  (e.g. implement, rework, and merge all live in `In Progress`).

  Stage kinds decide what Symphony does with an issue in that stage:

    * `queue`  - waiting for an agent to pick it up (dispatched)
    * `agent`  - an agent works it (dispatched)
    * `human`  - waiting on a person (not dispatched)
    * `parked` - deliberately on hold (not dispatched)
    * `done`   - finished

  Transitions say who moves an issue from one stage to the next (`agent` or
  `human`) and when (`criteria`), and are given to agents as their allowed moves.

  A stage with `approval` always needs a person to approve the move an agent
  makes out of it. A flow's `autopilot` (earned autonomy) makes every agent
  stage need approval until it has `streak` approvals in a row
  (`approval_streak` on the stage); a send-back resets the count.

  Definitions are plain, JSON-serialisable maps with string keys.
  """

  @kinds ["queue", "agent", "human", "parked", "done"]
  @dispatchable ["queue", "agent"]
  @movers ["agent", "human"]
  @backends ["codex", "claude", "opencode"]
  @efforts ["low", "medium", "high", "xhigh", "max"]
  @id_pattern ~r/^[a-z][a-z0-9-]{0,31}$/
  @default_streak 10

  @type stage :: map()
  @type t :: map()

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  The flow Symphony ships with: Todo -> Implement -> In Review -> Merge -> Done,
  with Rework and Blocked loops. Teams start from this until they edit it.
  """
  @spec default_template() :: t()
  def default_template do
    %{
      "version" => 0,
      "stages" => [
        stage("todo", "Todo", "queue", "Todo", nil, {78, 165}, instructions: "Pick the issue up: move it to In Progress, create the workpad, and start the implement stage."),
        stage("implement", "Implement", "agent", "In Progress", "implement", {290, 165},
          default: true,
          instructions: "Reproduce the problem, plan in the workpad, implement, validate, open or update the PR, and run the PR feedback sweep. Hand off to review only when the completion bar is met."
        ),
        stage("review", "In Review", "human", "In Review", nil, {500, 165}),
        stage("rework", "Rework", "agent", "In Progress", "rework", {395, 280},
          instructions: "A reviewer asked for a reset. Close the PR, delete its branch, start a fresh branch from origin/main, and switch the stage label to implement."
        ),
        stage("merge", "Merge", "agent", "In Progress", "merge", {710, 165}, instructions: "The PR is approved. Run the land skill until it is merged, then move the issue to Done."),
        stage("blocked", "Blocked", "parked", "In Progress", "blocked", {500, 44}),
        stage("done", "Done", "done", "Done", nil, {918, 165})
      ],
      "transitions" => [
        transition("todo", "implement", "agent", "An agent picks the issue up"),
        transition("implement", "review", "agent", "PR is open, checks are green, and the workpad is complete"),
        transition("implement", "blocked", "agent", "Blocked by missing access or information"),
        transition("review", "merge", "human", "The reviewer approves the PR"),
        transition("review", "rework", "human", "The reviewer asks for a different approach"),
        transition("review", "implement", "human", "The reviewer asks for small changes"),
        transition("rework", "implement", "agent", "The old PR is closed and a fresh branch is ready"),
        transition("merge", "done", "agent", "The PR is merged"),
        transition("merge", "blocked", "agent", "Landing is blocked"),
        transition("blocked", "implement", "human", "The blocker is resolved"),
        transition("blocked", "review", "human", "A human takes it from here")
      ]
    }
  end

  @doc """
  Validates and normalises a definition. Returns `{:ok, definition}` or
  `{:error, [message]}` listing every problem found.
  """
  @spec validate(map()) :: {:ok, t()} | {:error, [String.t()]}
  def validate(%{} = definition) do
    stages = definition |> Map.get("stages", []) |> List.wrap() |> Enum.map(&normalize_stage/1)
    transitions = definition |> Map.get("transitions", []) |> List.wrap() |> Enum.map(&normalize_transition/1)
    ids = Enum.map(stages, & &1["id"])

    autopilot = normalize_autopilot(Map.get(definition, "autopilot"))

    errors =
      stage_errors(stages) ++
        identity_errors(stages) ++
        transition_errors(transitions, MapSet.new(ids)) ++
        structure_errors(stages) ++
        autopilot_errors(autopilot)

    if errors == [] do
      {:ok,
       definition
       |> Map.merge(%{"stages" => stages, "transitions" => transitions, "autopilot" => autopilot, "version" => Map.get(definition, "version", 0)})
       |> Map.take(["version", "stages", "transitions", "autopilot", "updated_at", "updated_by"])}
    else
      {:error, Enum.uniq(errors)}
    end
  end

  def validate(_definition), do: {:error, ["definition must be an object"]}

  @doc """
  Finds the stage an issue is in from its Linear state and labels.

  An exact state + stage-label match wins. Otherwise a stage for that state
  without a label, then the state's `default` stage (so an `In Progress` issue
  with no stage label is in Implement).
  """
  @spec stage_for(t(), String.t() | nil, [String.t()], String.t()) :: stage() | nil
  def stage_for(definition, state_name, labels, prefix) when is_binary(state_name) do
    state = normalize(state_name)
    in_state = Enum.filter(definition["stages"], &(normalize(&1["linear_state"]) == state))
    stage_labels = labels |> Enum.map(&normalize/1) |> Enum.filter(&String.starts_with?(&1, prefix <> "/"))

    by_label =
      Enum.find(in_state, fn stage ->
        is_binary(stage["label"]) and (prefix <> "/" <> normalize(stage["label"])) in stage_labels
      end)

    by_label || Enum.find(in_state, &is_nil(&1["label"])) || Enum.find(in_state, & &1["default"])
  end

  def stage_for(_definition, _state, _labels, _prefix), do: nil

  @spec stage(t(), String.t() | nil) :: stage() | nil
  def stage(definition, id) when is_binary(id), do: Enum.find(definition["stages"], &(&1["id"] == id))
  def stage(_definition, _id), do: nil

  @spec dispatchable?(stage() | nil) :: boolean()
  def dispatchable?(%{"kind" => kind, "paused" => paused}), do: kind in @dispatchable and paused != true
  def dispatchable?(_stage), do: false

  @doc """
  Whether a person must approve the move an agent makes out of `stage`: always
  when the stage says so, and under earned autonomy until the stage has enough
  approvals in a row.
  """
  @spec requires_approval?(t(), stage() | nil) :: boolean()
  def requires_approval?(_definition, %{"approval" => true}), do: true

  # Earned autonomy covers stages where agents do the work, not queues.
  def requires_approval?(definition, %{"kind" => "agent"} = stage) do
    case autopilot(definition) do
      %{"enabled" => true, "streak" => needed} -> (stage["approval_streak"] || 0) < needed
      _ -> false
    end
  end

  def requires_approval?(_definition, _stage), do: false

  @spec autopilot(t()) :: %{String.t() => term()}
  def autopilot(definition), do: normalize_autopilot(definition["autopilot"])

  @spec default_streak() :: pos_integer()
  def default_streak, do: @default_streak

  @spec transitions_from(t(), String.t()) :: [map()]
  def transitions_from(definition, stage_id), do: Enum.filter(definition["transitions"], &(&1["from"] == stage_id))

  @doc """
  Linear workflow states the definition uses for dispatchable stages.
  """
  @spec active_states(t()) :: [String.t()]
  def active_states(definition) do
    definition["stages"] |> Enum.filter(&(&1["kind"] in @dispatchable)) |> Enum.map(& &1["linear_state"]) |> Enum.uniq()
  end

  # ------------------------------------------------------------------ builders

  defp stage(id, name, kind, state, label, {x, y}, opts \\ []) do
    %{
      "id" => id,
      "name" => name,
      "kind" => kind,
      "linear_state" => state,
      "label" => label,
      "default" => Keyword.get(opts, :default, false),
      "instructions" => Keyword.get(opts, :instructions, ""),
      "harness" => nil,
      "effort" => nil,
      "max_agents" => nil,
      "paused" => false,
      "approval" => false,
      "approval_streak" => 0,
      "checks" => [],
      "skill" => nil,
      "position" => %{"x" => x, "y" => y}
    }
  end

  defp transition(from, to, by, criteria), do: %{"from" => from, "to" => to, "by" => by, "criteria" => criteria}

  # ------------------------------------------------------------------ normalisation

  defp normalize_stage(%{} = stage) do
    %{
      "id" => stage |> Map.get("id") |> to_s() |> normalize(),
      "name" => stage |> Map.get("name") |> to_s() |> String.trim(),
      "kind" => stage |> Map.get("kind") |> to_s() |> normalize(),
      "linear_state" => stage |> Map.get("linear_state") |> to_s() |> String.trim(),
      "label" => stage |> Map.get("label") |> blank_to_nil() |> then(&(&1 && normalize(&1))),
      "default" => Map.get(stage, "default") == true,
      "instructions" => stage |> Map.get("instructions") |> to_s(),
      "harness" => blank_to_nil(Map.get(stage, "harness")),
      "effort" => blank_to_nil(Map.get(stage, "effort")),
      "max_agents" => Map.get(stage, "max_agents"),
      "paused" => Map.get(stage, "paused") == true,
      # A person approves before an issue leaves this stage.
      "approval" => Map.get(stage, "approval") == true,
      "approval_streak" => non_negative(Map.get(stage, "approval_streak")),
      # Shell commands Symphony runs in the workspace before it moves an issue on.
      "checks" => normalize_checks(Map.get(stage, "checks")),
      "position" => normalize_position(Map.get(stage, "position")),
      "skill" => normalize_skill(Map.get(stage, "skill"), stage |> Map.get("id") |> to_s() |> normalize())
    }
  end

  defp normalize_stage(_stage), do: %{"id" => "", "kind" => "", "name" => "", "linear_state" => "", "label" => nil}

  defp normalize_transition(%{} = transition) do
    %{
      "from" => transition |> Map.get("from") |> to_s() |> normalize(),
      "to" => transition |> Map.get("to") |> to_s() |> normalize(),
      "by" => transition |> Map.get("by", "agent") |> to_s() |> normalize(),
      "criteria" => transition |> Map.get("criteria") |> to_s() |> String.trim()
    }
  end

  defp normalize_transition(_transition), do: %{"from" => "", "to" => "", "by" => "", "criteria" => ""}

  defp normalize_position(%{"x" => x, "y" => y}) when is_number(x) and is_number(y), do: %{"x" => x, "y" => y}
  defp normalize_position(_position), do: %{"x" => 0, "y" => 0}

  # A stage's skill always lives at .codex/skills/<stage-id>/SKILL.md, whatever
  # path was suggested, so a draft can't point outside the skills folder.
  defp normalize_skill(%{"content" => content}, id) when is_binary(content) and content != "",
    do: %{"path" => ".codex/skills/#{id}/SKILL.md", "content" => String.slice(content, 0, 20_000)}

  defp normalize_skill(_skill, _id), do: nil

  # ------------------------------------------------------------------ validation

  defp stage_errors(stages) do
    Enum.flat_map(stages, fn stage ->
      label = stage["name"] |> blank_to_nil() || stage["id"]

      (stage_identity_errors(stage, label) ++ stage_option_errors(stage, label))
      |> Enum.filter(&is_binary/1)
    end)
  end

  defp stage_identity_errors(stage, label) do
    [
      !Regex.match?(@id_pattern, stage["id"]) && "stage id #{inspect(stage["id"])} must be lowercase letters, digits, or dashes",
      stage["name"] == "" && "stage #{label} needs a name",
      stage["kind"] not in @kinds && "stage #{label} has unknown kind #{inspect(stage["kind"])}",
      stage["linear_state"] == "" && "stage #{label} needs a Linear state"
    ]
  end

  defp stage_option_errors(stage, label) do
    [
      stage["label"] && !Regex.match?(@id_pattern, stage["label"]) && "stage #{label} label must be lowercase letters, digits, or dashes",
      stage["harness"] not in [nil | @backends] && "stage #{label} has unknown harness #{inspect(stage["harness"])}",
      stage["effort"] not in [nil | @efforts] && "stage #{label} has unknown thinking level #{inspect(stage["effort"])}",
      not valid_max_agents?(stage["max_agents"]) && "stage #{label} max agents must be a whole number from 1 to 100"
    ]
  end

  defp identity_errors(stages) do
    duplicate_ids = stages |> Enum.frequencies_by(& &1["id"]) |> Enum.filter(fn {_id, n} -> n > 1 end)

    duplicate_identity =
      stages
      |> Enum.frequencies_by(&{normalize(&1["linear_state"]), &1["label"]})
      |> Enum.filter(fn {_key, n} -> n > 1 end)

    defaults =
      stages
      |> Enum.filter(& &1["default"])
      |> Enum.frequencies_by(&normalize(&1["linear_state"]))
      |> Enum.filter(fn {_state, n} -> n > 1 end)

    Enum.map(duplicate_ids, fn {id, _} -> "two stages share the id #{inspect(id)}" end) ++
      Enum.map(duplicate_identity, fn {{state, label}, _} ->
        "two stages use Linear state #{inspect(state)} with #{if label, do: "label #{inspect(label)}", else: "no label"}"
      end) ++
      Enum.map(defaults, fn {state, _} -> "only one stage can be the default for #{inspect(state)}" end)
  end

  defp transition_errors(transitions, ids) do
    Enum.flat_map(transitions, fn t ->
      [
        not MapSet.member?(ids, t["from"]) && "a connection starts at unknown stage #{inspect(t["from"])}",
        not MapSet.member?(ids, t["to"]) && "a connection ends at unknown stage #{inspect(t["to"])}",
        t["from"] == t["to"] && "stage #{inspect(t["from"])} can't connect to itself",
        t["by"] not in @movers && "connection #{t["from"]} → #{t["to"]} must be moved by agent or human"
      ]
      |> Enum.filter(&is_binary/1)
    end) ++
      (transitions
       |> Enum.frequencies_by(&{&1["from"], &1["to"]})
       |> Enum.filter(fn {_key, n} -> n > 1 end)
       |> Enum.map(fn {{from, to}, _} -> "#{from} → #{to} is connected twice" end))
  end

  defp structure_errors(stages) do
    [
      stages == [] && "a factory needs at least one stage",
      (stages != [] and not Enum.any?(stages, &(&1["kind"] == "done"))) && "a factory needs a done stage",
      (stages != [] and not Enum.any?(stages, &(&1["kind"] in @dispatchable))) && "a factory needs at least one agent or queue stage"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp normalize_autopilot(%{} = autopilot) do
    %{"enabled" => Map.get(autopilot, "enabled") == true, "streak" => Map.get(autopilot, "streak", @default_streak)}
  end

  defp normalize_autopilot(_autopilot), do: %{"enabled" => false, "streak" => @default_streak}

  defp autopilot_errors(%{"streak" => streak}) when is_integer(streak) and streak >= 1 and streak <= 100, do: []
  defp autopilot_errors(_autopilot), do: ["approvals in a row must be a whole number from 1 to 100"]

  defp normalize_checks(checks) when is_list(checks) do
    checks
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.slice(&1, 0, 500))
    |> Enum.take(10)
  end

  defp normalize_checks(_checks), do: []

  defp non_negative(n) when is_integer(n) and n > 0, do: n
  defp non_negative(_n), do: 0

  defp valid_max_agents?(nil), do: true
  defp valid_max_agents?(n) when is_integer(n) and n >= 1 and n <= 100, do: true
  defp valid_max_agents?(_n), do: false

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)

  defp blank_to_nil(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp blank_to_nil(_value), do: nil

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""
end
