defmodule SymphonyElixir.Factory.Assistant do
  @moduledoc """
  Drafts factory stages and whole flows with the configured agent harness.

  `draft/4` takes a plain-language request for one stage ("before review, run
  e2e against the preview deploy") and asks the harness CLI for the stage's
  agent instructions, suggested connections, and optionally a skill file.
  `draft_flow/3` designs a whole flow (stages, connections, instructions, and
  skills) from a description, starting from the flow the scope uses today.

  The CLI runs one-shot in an empty scratch directory with file, shell, and web
  tools disallowed where the harness supports it, so it can only produce text.
  Nothing it returns is applied until a person reviews it in the editor.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Factory.Definition

  @timeout_ms 180_000
  @flow_timeout_ms 420_000
  @runtime_fields ["harness", "effort", "max_agents", "paused"]
  @max_output_bytes 200_000

  @type suggestion :: %{
          instructions: String.t(),
          transitions: [map()],
          skill: %{path: String.t(), content: String.t()} | nil
        }

  @type flow_suggestion :: %{
          summary: String.t(),
          definition: Definition.t(),
          changes: %{added: [String.t()], removed: [String.t()], changed: [String.t()]}
        }

  @spec draft(map(), String.t(), String.t(), keyword()) :: {:ok, suggestion()} | {:error, String.t()}
  def draft(definition, stage_id, request, opts \\ []) do
    with %{} = stage <- Enum.find(definition["stages"] || [], &(&1["id"] == stage_id)) || {:error, "That stage isn't in the flow."},
         {:ok, request} <- clean_request(request),
         prompt = build_prompt(definition, stage, request, Keyword.get(opts, :skill, true)),
         {:ok, output} <- run(prompt, Keyword.get(opts, :harness) || harness(), Keyword.get(opts, :timeout_ms, @timeout_ms)),
         {:ok, suggestion} <- parse(output) do
      {:ok, sanitize(suggestion, definition, stage_id)}
    end
  end

  @doc """
  Designs a whole flow from a description, starting from `base` (the flow the
  scope uses now). Options: `:scope_label` ("project Checkout API"),
  `:linear_states` (states the team's Linear workflow has), `:label_prefix`,
  `:skills` (draft skill files for agent stages, default true), `:harness`,
  `:timeout_ms`.

  The draft is validated like a save. When it isn't a valid flow the harness
  gets one chance to fix the listed problems. Runtime controls (harness,
  thinking, caps, pause) carry over for stages that keep their id.
  """
  @spec draft_flow(map(), String.t(), keyword()) :: {:ok, flow_suggestion()} | {:error, String.t()}
  def draft_flow(base, request, opts \\ []) do
    harness = Keyword.get(opts, :harness) || harness()
    timeout_ms = Keyword.get(opts, :timeout_ms, @flow_timeout_ms)

    with {:ok, request} <- clean_request(request, "Describe the flow you want."),
         {:ok, output} <- run(build_flow_prompt(base, request, opts), harness, timeout_ms),
         {:ok, draft} <- parse(output, "stages") do
      case flow_candidate(draft, base) do
        {:ok, definition} ->
          {:ok, flow_suggestion(draft, definition, base)}

        {:error, errors} ->
          repair_flow(draft, errors, base, harness, timeout_ms)
      end
    end
  end

  defp repair_flow(draft, errors, base, harness, timeout_ms) do
    with {:ok, output} <- run(build_repair_prompt(draft, errors), harness, timeout_ms),
         {:ok, repaired} <- parse(output, "stages") do
      case flow_candidate(repaired, base) do
        {:ok, definition} ->
          {:ok, flow_suggestion(repaired, definition, base)}

        {:error, errors} ->
          {:error, "The assistant's flow still had problems: " <> Enum.join(Enum.take(errors, 3), "; ") <> ". Try again or rephrase."}
      end
    end
  end

  @doc false
  @spec build_flow_prompt(map(), String.t(), keyword()) :: String.t()
  def build_flow_prompt(base, request, opts) do
    prefix = Keyword.get(opts, :label_prefix, "factory")
    skills? = Keyword.get(opts, :skills, true)

    states =
      case Keyword.get(opts, :linear_states, []) do
        [] -> "Use the standard Linear states: Backlog, Todo, In Progress, In Review, Done, Canceled."
        states -> "Linear states known to exist: #{Enum.join(states, ", ")}. Stick to these; a stage in a state the team doesn't have is never reached."
      end

    """
    You design the AI software factory for #{Keyword.get(opts, :scope_label, "a team")}. Coding agents work
    Linear issues through a flow of stages. Symphony dispatches an agent for every issue in a
    "queue" or "agent" stage and gives it that stage's instructions and the moves it may make.

    How stages work:
    - A stage is a Linear workflow state plus an optional stage label (Linear label `#{prefix}/<label>`).
      Many stages can share one state by using different labels (e.g. implement, rework, and merge
      all in "In Progress"). #{states}
    - kind is one of: "queue" (waiting for an agent), "agent" (an agent works it), "human" (waiting on
      a person), "parked" (on hold, never dispatched), "done" (finished).
    - id and label: lowercase letters, digits, dashes; ids are unique. No two stages may share the same
      state and label (or both have no label in the same state). Mark at most one stage per state
      "default": true; it is used for issues in that state with no stage label.
    - The flow needs at least one queue or agent stage and at least one done stage.
    - Connections ("transitions") say who moves an issue ("agent" or "human") from one stage to another
      and when ("criteria", one sentence). Include loops back for failures and a way out of blocked stages.

    The flow it uses today:
    #{flow_outline(base)}

    What they want:
    <request>
    #{request}
    </request>

    Design the complete new flow (not a diff). Keep existing stage ids where a stage keeps its purpose.
    For every agent and queue stage write "instructions": concrete steps an agent with the repo checked
    out, git, `gh`, and a Linear tool should follow, and what done looks like (under 200 words).
    #{if skills?, do: ~s(For agent stages that need a repeatable procedure, add "skill": Markdown with YAML front matter `name` and `description`, then steps and commands. Otherwise "skill": null.), else: ~s(Set every "skill" to null.)}

    Reply with ONLY one JSON object, no prose and no code fences:
    {"summary": "two sentences on the design",
     "stages": [{"id", "name", "kind", "linear_state", "label" (or null), "default", "instructions", "skill"}],
     "transitions": [{"from", "to", "by", "criteria"}]}
    """
  end

  defp build_repair_prompt(draft, errors) do
    """
    This factory flow JSON has problems:
    #{Enum.map_join(errors, "\n", &("- " <> &1))}

    Fix them and reply with ONLY the corrected JSON object with the same keys ("summary", "stages",
    "transitions"). No prose, no code fences.

    #{Jason.encode!(Map.take(draft, ["summary", "stages", "transitions"]))}
    """
  end

  defp flow_outline(base) do
    stages =
      Enum.map_join(base["stages"] || [], "\n", fn s ->
        label = if s["label"], do: ", label #{s["label"]}", else: ""
        instructions = s["instructions"] |> to_string() |> String.slice(0, 300)
        "- #{s["id"]}: #{s["name"]} (#{s["kind"]}, state #{inspect(s["linear_state"])}#{label})#{if instructions != "", do: ": " <> instructions, else: ""}"
      end)

    transitions =
      Enum.map_join(base["transitions"] || [], "\n", fn t -> "- #{t["from"]} -> #{t["to"]} (#{t["by"]}): #{t["criteria"]}" end)

    "Stages:\n#{stages}\nConnections:\n#{transitions}"
  end

  # The drafted flow as a definition: base's runtime controls carried over,
  # skills wrapped, validated like a save, then laid out on the grid.
  defp flow_candidate(draft, base) do
    base_stages = Map.new(base["stages"] || [], &{&1["id"], &1})

    stages =
      draft
      |> Map.get("stages")
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn stage ->
        id = stage |> Map.get("id") |> to_string() |> String.trim() |> String.downcase()
        carried = base_stages |> Map.get(id, %{}) |> Map.take(@runtime_fields)

        stage
        |> Map.take(["id", "name", "kind", "linear_state", "label", "default", "instructions"])
        |> Map.merge(carried)
        |> Map.put("skill", draft_skill(stage["skill"]))
      end)

    transitions = draft |> Map.get("transitions") |> List.wrap() |> Enum.filter(&is_map/1)

    with {:ok, definition} <- Definition.validate(%{"stages" => stages, "transitions" => transitions}) do
      {:ok, definition |> Map.delete("version") |> layout(base)}
    end
  end

  defp draft_skill(content) when is_binary(content) and content != "", do: %{"content" => content}
  defp draft_skill(%{"content" => content}), do: draft_skill(content)
  defp draft_skill(_skill), do: nil

  defp flow_suggestion(draft, definition, base) do
    before = Map.new(base["stages"] || [], &{&1["id"], &1})
    after_ids = MapSet.new(definition["stages"], & &1["id"])

    changed =
      definition["stages"]
      |> Enum.filter(fn stage ->
        old = before[stage["id"]]
        old && Map.take(old, ["name", "kind", "linear_state", "label", "instructions"]) != Map.take(stage, ["name", "kind", "linear_state", "label", "instructions"])
      end)

    %{
      summary: draft |> Map.get("summary", "") |> to_string() |> String.slice(0, 1_000),
      definition: definition,
      changes: %{
        added: for(stage <- definition["stages"], not Map.has_key?(before, stage["id"]), do: stage["name"]),
        removed: for({id, stage} <- before, not MapSet.member?(after_ids, id), do: stage["name"]),
        changed: Enum.map(changed, & &1["name"])
      }
    }
  end

  # ------------------------------------------------------------------ layout

  @column_x 80
  @column_gap 220
  @main_row_y 160
  @row_gap 120
  @top_y 40
  @waiting_kinds ["human", "parked"]

  @doc """
  Lays a flow out left to right. Stages keep their positions when the draft has
  exactly the stages `base` has. Otherwise:

    * the spine (the longest forward path from the start to the first done
      stage, so the real pipeline rather than a shortcut through "blocked")
      runs along one row
    * other waiting stages (human, parked) sit above the spine, other agent
      stages (rework loops) below it, each in the column between the spine
      stages they connect to
    * other done stages sit under the spine's end
  """
  @spec layout(map(), map()) :: map()
  def layout(definition, base \\ %{}) do
    ids = Enum.map(definition["stages"], & &1["id"])
    base_positions = Map.new(base["stages"] || [], &{&1["id"], &1["position"]})

    positions =
      if Enum.sort(ids) == Enum.sort(Map.keys(base_positions)), do: base_positions, else: grid_positions(definition)

    %{definition | "stages" => Enum.map(definition["stages"], &Map.put(&1, "position", positions[&1["id"]]))}
  end

  defp grid_positions(definition) do
    stages = definition["stages"]
    edges = Enum.map(definition["transitions"], &{&1["from"], &1["to"]})
    next = Enum.group_by(edges, &elem(&1, 0), &elem(&1, 1))
    incoming = MapSet.new(edges, &elem(&1, 1))

    # Start from the queue stages, else stages nothing leads into, else the first.
    roots =
      [Enum.filter(stages, &(&1["kind"] == "queue")), Enum.reject(stages, &MapSet.member?(incoming, &1["id"])), [hd(stages)]]
      |> Enum.find(&(&1 != []))
      |> Enum.map(& &1["id"])

    forward = forward_edges(roots ++ Enum.map(stages, & &1["id"]), next)
    spine = spine(roots, forward, stages)
    columns = Map.new(Enum.with_index(spine))
    last = max(length(spine) - 1, 0)

    {placed, _taken} =
      stages
      |> Enum.reject(&Map.has_key?(columns, &1["id"]))
      |> Enum.reduce({Map.new(columns, fn {id, col} -> {id, {col, 0}} end), MapSet.new(columns, fn {_id, col} -> {col, 0} end)}, fn stage, {acc, taken} ->
        {col, direction} = off_spine_slot(stage, columns, edges, last)
        row = free_row(taken, col, direction)
        {Map.put(acc, stage["id"], {col, row}), MapSet.put(taken, {col, row})}
      end)

    # Rows above the spine are negative; shift down so the top row stays on canvas.
    top = placed |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.min()
    offset = max(@top_y - (@main_row_y + top * @row_gap), 0)

    Map.new(placed, fn {id, {col, row}} ->
      {id, %{"x" => @column_x + col * @column_gap, "y" => @main_row_y + row * @row_gap + offset}}
    end)
  end

  # Waiting stages go above the spine, the rest below; extra done stages under
  # the spine's end. The column is the middle of the spine stages it touches.
  defp off_spine_slot(%{"kind" => "done"}, _columns, _edges, last), do: {last, 1}

  defp off_spine_slot(stage, columns, edges, last) do
    id = stage["id"]

    neighbours =
      for {from, to} <- edges, id in [from, to], col = columns[other_end(from, to, id)], col != nil, do: col

    col = if neighbours == [], do: last, else: round(Enum.sum(neighbours) / length(neighbours))
    {col, if(stage["kind"] in @waiting_kinds, do: -1, else: 1)}
  end

  defp other_end(id, to, id), do: to
  defp other_end(from, _to, _id), do: from

  defp free_row(taken, col, direction) do
    Stream.iterate(direction, &(&1 + direction)) |> Enum.find(&(not MapSet.member?(taken, {col, &1})))
  end

  # Edges that don't loop back: a depth-first walk in connection order drops
  # edges to stages still on the walk's stack.
  defp forward_edges(starts, next) do
    {_visited, forward} =
      Enum.reduce(starts, {%{}, []}, fn id, {visited, forward} -> walk(id, next, [], visited, forward) end)

    # Connection order breaks ties between equally long paths.
    Enum.reverse(forward)
  end

  defp walk(id, next, stack, visited, forward) do
    if Map.has_key?(visited, id) do
      {visited, forward}
    else
      next
      |> Map.get(id, [])
      |> Enum.reduce({Map.put(visited, id, true), forward}, &walk_edge(id, &1, &2, next, [id | stack]))
    end
  end

  defp walk_edge(id, to, {visited, forward}, next, stack) do
    if to in stack, do: {visited, forward}, else: walk(to, next, stack, visited, [{id, to} | forward])
  end

  # The longest forward path from a root to the first done stage it reaches.
  defp spine(roots, forward, stages) do
    target = Enum.find_value(stages, fn stage -> stage["kind"] == "done" && stage["id"] end)
    succ = Enum.group_by(forward, &elem(&1, 0), &elem(&1, 1))

    {best, _memo} =
      Enum.reduce(roots, {[], %{}}, fn root, {best, memo} ->
        {path, memo} = longest(root, target, succ, memo)
        {if(length(path) > length(best), do: path, else: best), memo}
      end)

    if best == [], do: roots |> Enum.take(1), else: best
  end

  defp longest(id, id, _succ, memo), do: {[id], memo}

  defp longest(id, target, succ, memo) do
    case Map.fetch(memo, id) do
      {:ok, path} ->
        {path, memo}

      :error ->
        {best, memo} =
          succ
          |> Map.get(id, [])
          |> Enum.reduce({[], memo}, fn to, {best, memo} ->
            {path, memo} = longest(to, target, succ, memo)
            {if(length(path) > length(best), do: path, else: best), memo}
          end)

        path = if best == [], do: [], else: [id | best]
        {path, Map.put(memo, id, path)}
    end
  end

  @doc false
  @spec build_prompt(map(), map(), String.t(), boolean()) :: String.t()
  def build_prompt(definition, stage, request, skill?) do
    stages =
      Enum.map_join(definition["stages"], "\n", fn s ->
        "- #{s["id"]}: #{s["name"]} (#{s["kind"]}, Linear state #{inspect(s["linear_state"])}#{if s["label"], do: ", label #{s["label"]}", else: ""})"
      end)

    transitions =
      Enum.map_join(definition["transitions"], "\n", fn t ->
        "- #{t["from"]} -> #{t["to"]} (moved by #{t["by"]})#{if t["criteria"] != "", do: ": #{t["criteria"]}", else: ""}"
      end)

    """
    You design stages for an AI software factory. Coding agents work Linear issues through a flow of
    stages; each agent-run stage gives the agent instructions, and connections say who moves an issue
    to the next stage and when.

    Current flow for this team:
    Stages:
    #{stages}
    Connections:
    #{transitions}

    The stage to design is `#{stage["id"]}` ("#{stage["name"]}", kind #{stage["kind"]}).
    What the team wants it to do:
    <request>
    #{request}
    </request>

    Write:
    1. "instructions": what an agent must do in this stage, as concrete steps, and what done looks like.
       Assume the agent has the repo checked out, `gh` and git, and a Linear tool. Under 250 words.
    2. "transitions": connections into and out of this stage that the flow needs, using only the stage
       ids listed above. Each has "from", "to", "by" ("agent" or "human"), and "criteria" (one sentence).
    #{if skill?, do: ~s(3. "skill": a reusable skill file for this stage with "path" \(".codex/skills/<stage-id>/SKILL.md"\) and "content" \(Markdown with a YAML front matter `name` and `description`, then steps and commands\).), else: ~s(3. "skill": null.)}

    Reply with ONLY one JSON object with keys "instructions", "transitions", "skill". No prose, no code fences.
    """
  end

  defp clean_request(request, empty_message \\ "Describe what the stage should do.")

  defp clean_request(request, empty_message) when is_binary(request) do
    request = String.trim(request)

    cond do
      request == "" -> {:error, empty_message}
      String.length(request) > 4_000 -> {:error, "Keep the description under 4,000 characters."}
      true -> {:ok, request}
    end
  end

  defp clean_request(_request, empty_message), do: {:error, empty_message}

  # The config schema only allows codex, claude, or opencode.
  defp harness, do: Config.settings!().agent.backend || "claude"

  # ------------------------------------------------------------------ running the CLI

  defp run(prompt, harness, timeout_ms) do
    dir = Path.join(System.tmp_dir!(), "symphony-assist-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      {executable, args} = command(harness, prompt, dir)

      case System.find_executable(executable) do
        nil -> {:error, "The #{harness} CLI (#{executable}) isn't installed where Symphony runs."}
        path -> run_port(path, args, dir, timeout_ms)
      end
    after
      File.rm_rf(dir)
    end
  end

  defp command("claude", prompt, _dir) do
    base = Config.settings!().claude.command |> String.split() |> List.first() || "claude"
    {base, ["-p", prompt, "--output-format", "json", "--disallowedTools", "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch"]}
  end

  defp command("codex", prompt, dir) do
    {"codex", ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--output-last-message", Path.join(dir, "last.txt"), prompt]}
  end

  defp command("opencode", prompt, _dir), do: {"opencode", ["run", prompt]}

  # stdin comes from /dev/null: an open stdin makes `claude -p` wait 3s for
  # input and print a warning ahead of its JSON.
  defp run_port(executable, args, dir, timeout_ms) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", ~s(exec "$0" "$@" < /dev/null), executable | args],
        cd: dir
      ])

    collect(port, dir, [], 0, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp collect(port, dir, acc, size, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when size + byte_size(data) <= @max_output_bytes ->
        collect(port, dir, [acc, data], size + byte_size(data), deadline)

      {^port, {:data, _data}} ->
        kill(port)
        {:error, "The assistant's reply was too long."}

      {^port, {:exit_status, 0}} ->
        last = Path.join(dir, "last.txt")
        {:ok, if(File.exists?(last), do: File.read!(last), else: IO.iodata_to_binary(acc))}

      {^port, {:exit_status, status}} ->
        Logger.warning("Factory assistant exited status=#{status} output=#{acc |> IO.iodata_to_binary() |> String.slice(0, 500)}")
        {:error, "The assistant failed (exit #{status}). Check the harness is signed in where Symphony runs."}
    after
      remaining ->
        kill(port)
        {:error, "The assistant took too long. Try a shorter description."}
    end
  end

  defp kill(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid), do: System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
    Port.close(port)
  catch
    _kind, _reason -> :ok
  end

  # ------------------------------------------------------------------ parsing

  @doc false
  @spec parse(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(output, required \\ "instructions") do
    with {:ok, json} <- first_json_object(output),
         {:ok, %{} = decoded} <- Jason.decode(json),
         {:ok, draft} <- unwrap(decoded, required) do
      {:ok, draft}
    else
      _ -> {:error, "The assistant didn't return a usable draft. Try again or rephrase."}
    end
  end

  # `claude --output-format json` wraps the model's text in "result"; CLIs may
  # also print warnings around it. A stage draft must at least have
  # instructions, a flow draft at least one stage.
  defp unwrap(%{"result" => result}, required) when is_binary(result), do: parse(result, required)
  defp unwrap(%{"instructions" => instructions} = draft, "instructions") when is_binary(instructions) and instructions != "", do: {:ok, draft}
  defp unwrap(%{"stages" => [_ | _]} = draft, "stages"), do: {:ok, draft}
  defp unwrap(_decoded, _required), do: :error

  defp first_json_object(text) do
    text = text |> String.replace(~r/```(?:json)?/, "") |> String.trim()

    case :binary.match(text, "{") do
      {start, _} ->
        case balanced_end(text, start) do
          nil -> :error
          stop -> {:ok, binary_part(text, start, stop - start + 1)}
        end

      :nomatch ->
        :error
    end
  end

  # Index of the brace closing the object that starts at `start`, honouring strings.
  defp balanced_end(text, start) do
    text
    |> binary_part(start, byte_size(text) - start)
    |> :binary.bin_to_list()
    |> scan(start, 0, false, false)
  end

  defp scan([], _index, _depth, _in_string, _escaped), do: nil
  defp scan([_char | rest], index, depth, in_string, true), do: scan(rest, index + 1, depth, in_string, false)
  defp scan([?\\ | rest], index, depth, true, false), do: scan(rest, index + 1, depth, true, true)
  defp scan([?" | rest], index, depth, in_string, false), do: scan(rest, index + 1, depth, not in_string, false)
  defp scan([_char | rest], index, depth, true, false), do: scan(rest, index + 1, depth, true, false)
  defp scan([?{ | rest], index, depth, false, false), do: scan(rest, index + 1, depth + 1, false, false)
  defp scan([?} | _rest], index, 1, false, false), do: index
  defp scan([?} | rest], index, depth, false, false), do: scan(rest, index + 1, depth - 1, false, false)
  defp scan([_char | rest], index, depth, false, false), do: scan(rest, index + 1, depth, false, false)

  defp usable_transition?(%{"from" => from, "to" => to}, ids, stage_id) do
    MapSet.member?(ids, from) and MapSet.member?(ids, to) and from != to and stage_id in [from, to]
  end

  defp usable_transition?(_transition, _ids, _stage_id), do: false

  # Keep only what the editor can use: known stage ids, valid movers, sane sizes.
  defp sanitize(suggestion, definition, stage_id) do
    ids = MapSet.new(definition["stages"], & &1["id"])

    transitions =
      suggestion
      |> Map.get("transitions", [])
      |> List.wrap()
      |> Enum.filter(&usable_transition?(&1, ids, stage_id))
      |> Enum.map(fn t ->
        %{from: t["from"], to: t["to"], by: if(t["by"] == "human", do: "human", else: "agent"), criteria: t |> Map.get("criteria", "") |> to_string() |> String.slice(0, 300)}
      end)
      |> Enum.uniq_by(&{&1.from, &1.to})

    %{
      instructions: suggestion |> Map.get("instructions", "") |> to_string() |> String.slice(0, 4_000),
      transitions: transitions,
      skill: sanitize_skill(Map.get(suggestion, "skill"), stage_id)
    }
  end

  defp sanitize_skill(%{"content" => content}, stage_id) when is_binary(content) and content != "" do
    %{path: ".codex/skills/#{stage_id}/SKILL.md", content: String.slice(content, 0, 20_000)}
  end

  defp sanitize_skill(_skill, _stage_id), do: nil
end
