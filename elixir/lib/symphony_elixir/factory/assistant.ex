defmodule SymphonyElixir.Factory.Assistant do
  @moduledoc """
  Drafts a factory stage with the team's own agent harness.

  Given a plain-language request ("before review, run e2e against the preview
  deploy"), it asks the configured harness CLI for the stage's agent
  instructions, suggested connections, and optionally a skill file, as JSON.

  The CLI runs one-shot in an empty scratch directory with file, shell, and web
  tools disallowed where the harness supports it, so it can only produce text.
  Nothing it returns is applied until a person reviews it in the editor.
  """

  require Logger

  alias SymphonyElixir.Config

  @timeout_ms 180_000
  @max_output_bytes 200_000

  @type suggestion :: %{
          instructions: String.t(),
          transitions: [map()],
          skill: %{path: String.t(), content: String.t()} | nil
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

  defp clean_request(request) when is_binary(request) do
    request = String.trim(request)

    cond do
      request == "" -> {:error, "Describe what the stage should do."}
      String.length(request) > 2_000 -> {:error, "Keep the description under 2,000 characters."}
      true -> {:ok, request}
    end
  end

  defp clean_request(_request), do: {:error, "Describe what the stage should do."}

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
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(output) do
    with {:ok, json} <- first_json_object(output),
         {:ok, %{} = decoded} <- Jason.decode(json),
         {:ok, draft} <- unwrap(decoded) do
      {:ok, draft}
    else
      _ -> {:error, "The assistant didn't return a usable draft. Try again or rephrase."}
    end
  end

  # `claude --output-format json` wraps the model's text in "result"; CLIs may
  # also print warnings around it. A draft must at least have instructions.
  defp unwrap(%{"result" => result}) when is_binary(result), do: parse(result)
  defp unwrap(%{"instructions" => instructions} = draft) when is_binary(instructions) and instructions != "", do: {:ok, draft}
  defp unwrap(_decoded), do: :error

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
