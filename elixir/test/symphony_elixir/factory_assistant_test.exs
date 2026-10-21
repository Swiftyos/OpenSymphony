defmodule SymphonyElixir.FactoryAssistantTest do
  use SymphonyElixir.TestSupport

  # Real git/process/HTTP integration; excluded by `make test-fast`.
  @moduletag :slow

  alias SymphonyElixir.Factory.{Assistant, Definition}

  test "parses claude's JSON wrapper, fenced JSON, and prose around the object" do
    draft = %{"instructions" => "Run e2e.", "transitions" => [], "skill" => nil}
    wrapped = Jason.encode!(%{"type" => "result", "result" => "Here you go:\n```json\n" <> Jason.encode!(draft) <> "\n```"})

    assert {:ok, ^draft} = Assistant.parse(wrapped)
    assert {:ok, ^draft} = Assistant.parse("Sure! " <> Jason.encode!(draft) <> " Hope that helps {not json}")
    assert {:ok, %{"instructions" => "a } b"}} = Assistant.parse(~s({"instructions": "a } b"}))
    assert {:error, _} = Assistant.parse("I can't help with that.")

    # Real claude output: a stdin warning printed ahead of the JSON wrapper.
    noisy = "Warning: no stdin data received in 3s, proceeding without it.\n" <> wrapped
    assert {:ok, ^draft} = Assistant.parse(noisy)

    # A wrapper or object without instructions is not a draft.
    assert {:error, _} = Assistant.parse(Jason.encode!(%{"result" => "Sorry, I can't."}))
    assert {:error, _} = Assistant.parse(Jason.encode!(%{"duration_ms" => 5}))
    assert {:error, _} = Assistant.parse(~s({"instructions": ""}))
  end

  test "the prompt describes the team's flow and the request" do
    definition = Definition.default_template()
    stage = Definition.stage(definition, "merge")
    prompt = Assistant.build_prompt(definition, stage, "Land with a merge queue.", true)

    assert prompt =~ "- review: In Review (human, Linear state \"In Review\")"
    assert prompt =~ "- review -> merge (moved by human): The reviewer approves the PR"
    assert prompt =~ "<request>\nLand with a merge queue.\n</request>"
    assert prompt =~ ".codex/skills/<stage-id>/SKILL.md"
  end

  test "requests are validated and missing CLIs give a clear error" do
    definition = Definition.default_template()
    assert {:error, "Describe what the stage should do."} = Assistant.draft(definition, "merge", "   ")
    assert {:error, "That stage isn't in the flow."} = Assistant.draft(definition, "nope", "x")
    assert {:error, "Keep the description under 4,000 characters."} = Assistant.draft(definition, "merge", String.duplicate("a", 4_001))
  end

  describe "running the harness" do
    setup do
      bin = Path.join(System.tmp_dir!(), "symphony-assist-bin-#{System.unique_integer([:positive])}")
      File.mkdir_p!(bin)
      path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> path)
      write_workflow_file!(Workflow.workflow_file_path())

      on_exit(fn ->
        System.put_env("PATH", path)
        File.rm_rf!(bin)
      end)

      %{bin: bin, definition: Definition.default_template()}
    end

    defp fake(bin, name, script) do
      file = Path.join(bin, name)
      File.write!(file, "#!/bin/sh\n" <> script)
      File.chmod!(file, 0o755)
    end

    @draft %{
      "instructions" => "Run e2e.",
      "transitions" => [
        %{"from" => "implement", "to" => "merge", "by" => "agent", "criteria" => "green"},
        %{"from" => "merge", "to" => "done", "by" => "human"},
        %{"from" => "review", "to" => "done", "by" => "agent"},
        %{"from" => "merge", "to" => "nowhere", "by" => "agent"},
        %{"from" => "merge", "to" => "merge", "by" => "agent"},
        "junk"
      ],
      "skill" => %{"path" => "../../etc/passwd", "content" => "---\nname: merge\n---\nsteps"}
    }

    test "claude: drafts are parsed and trimmed to what the editor can use", %{bin: bin, definition: definition} do
      wrapped = Jason.encode!(%{"result" => "Draft:\n" <> Jason.encode!(@draft)})
      fake(bin, "claude", "cat <<'JSON'\n#{wrapped}\nJSON\n")

      assert {:ok, suggestion} = Assistant.draft(definition, "merge", "Land it.", harness: "claude")
      assert suggestion.instructions == "Run e2e."
      # Only known stages, only connections touching this stage, no self-loops, movers normalised.
      assert suggestion.transitions == [
               %{from: "implement", to: "merge", by: "agent", criteria: "green"},
               %{from: "merge", to: "done", by: "human", criteria: ""}
             ]

      # The skill path is always this stage's, whatever the model suggested.
      assert suggestion.skill == %{path: ".codex/skills/merge/SKILL.md", content: "---\nname: merge\n---\nsteps"}
    end

    test "codex: the last message file wins; harness defaults come from config", %{bin: bin, definition: definition} do
      draft = Jason.encode!(Map.put(@draft, "skill", nil))
      fake(bin, "codex", ~s(while [ "$1" != "--output-last-message" ]; do shift; done; printf '%s' '#{draft}' > "$2"; echo noise))

      assert {:ok, %{skill: nil}} = Assistant.draft(definition, "merge", "Land it.", harness: "codex")

      write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "codex")
      assert {:ok, %{instructions: "Run e2e."}} = Assistant.draft(definition, "merge", "Land it.")
    end

    test "opencode output is read from stdout", %{bin: bin, definition: definition} do
      fake(bin, "opencode", "printf '%s' '#{Jason.encode!(@draft)}'")
      assert {:ok, %{instructions: "Run e2e."}} = Assistant.draft(definition, "merge", "Land it.", harness: "opencode")
    end

    test "failures, timeouts, oversized replies, and missing CLIs give plain errors", %{bin: bin, definition: definition} do
      fake(bin, "claude", "echo 'not signed in'; exit 3")
      assert {:error, "The assistant failed (exit 3)." <> _} = Assistant.draft(definition, "merge", "x", harness: "claude")

      fake(bin, "claude", "sleep 5")
      assert {:error, "The assistant took too long." <> _} = Assistant.draft(definition, "merge", "x", harness: "claude", timeout_ms: 200)

      fake(bin, "claude", "yes 0123456789 | head -c 400000")
      assert {:error, "The assistant's reply was too long."} = Assistant.draft(definition, "merge", "x", harness: "claude")

      fake(bin, "claude", "echo 'no json here {unclosed'")
      assert {:error, "The assistant didn't return a usable draft." <> _} = Assistant.draft(definition, "merge", "x", harness: "claude")

      File.rm!(Path.join(bin, "claude"))
      System.put_env("PATH", bin)
      assert {:error, "The claude CLI (claude) isn't installed" <> _} = Assistant.draft(definition, "merge", "x", harness: "claude")
    end

    test "non-text requests are refused", %{definition: definition} do
      assert {:error, "Describe what the stage should do."} = Assistant.draft(definition, "merge", nil)
    end

    @flow %{
      "summary" => "Adds a security review.",
      "stages" => [
        %{"id" => "todo", "name" => "Todo", "kind" => "queue", "linear_state" => "Todo", "instructions" => "Pick it up."},
        %{
          "id" => "implement",
          "name" => "Build",
          "kind" => "agent",
          "linear_state" => "In Progress",
          "label" => "implement",
          "default" => true,
          "instructions" => "Build it.",
          "skill" => "---\nname: build\n---\nsteps"
        },
        %{"id" => "security", "name" => "Security", "kind" => "agent", "linear_state" => "In Progress", "label" => "security", "instructions" => "Audit.", "skill" => %{"content" => "audit"}},
        %{"id" => "blocked", "name" => "Blocked", "kind" => "parked", "linear_state" => "In Progress", "label" => "blocked"},
        %{"id" => "review", "name" => "In Review", "kind" => "human", "linear_state" => "In Review"},
        %{"id" => "done", "name" => "Done", "kind" => "done", "linear_state" => "Done"},
        %{"id" => "orphan", "name" => "Orphan", "kind" => "parked", "linear_state" => "Backlog"},
        "junk"
      ],
      "transitions" => [
        %{"from" => "todo", "to" => "implement", "by" => "agent", "criteria" => "picked up"},
        %{"from" => "implement", "to" => "security", "by" => "agent", "criteria" => "PR open"},
        %{"from" => "implement", "to" => "blocked", "by" => "agent", "criteria" => "stuck"},
        %{"from" => "security", "to" => "implement", "by" => "agent", "criteria" => "findings"},
        %{"from" => "security", "to" => "review", "by" => "agent", "criteria" => "clean"},
        %{"from" => "review", "to" => "done", "by" => "human", "criteria" => "approved"}
      ]
    }

    test "flows: a whole flow is drafted, validated, laid out, and keeps runtime controls", %{bin: bin, definition: definition} do
      fake(bin, "claude", "cat <<'JSON'\n#{Jason.encode!(%{"result" => Jason.encode!(@flow)})}\nJSON\n")
      base = update_in(definition["stages"], fn stages -> Enum.map(stages, &if(&1["id"] == "implement", do: Map.merge(&1, %{"harness" => "codex", "max_agents" => 3}), else: &1)) end)

      assert {:ok, suggestion} =
               Assistant.draft_flow(base, "Add a security review.", harness: "claude", scope_label: "the project Checkout", linear_states: ["Todo", "In Progress"])

      assert suggestion.summary == "Adds a security review."
      stages = Map.new(suggestion.definition["stages"], &{&1["id"], &1})
      assert Map.keys(stages) |> Enum.sort() == ["blocked", "done", "implement", "orphan", "review", "security", "todo"]
      refute Map.has_key?(suggestion.definition, "version")

      # Controls carry over by id; skills are wrapped at the stage's own path.
      assert %{"harness" => "codex", "max_agents" => 3, "skill" => %{"path" => ".codex/skills/implement/SKILL.md"}} = stages["implement"]
      assert stages["security"]["skill"] == %{"path" => ".codex/skills/security/SKILL.md", "content" => "audit"}
      assert stages["todo"]["skill"] == nil

      # The start-to-done pipeline runs along one row, waiting stages sit above the
      # stages they connect to, and unconnected stages go at the end.
      assert stages["todo"]["position"] == %{"x" => 80, "y" => 160}
      assert stages["implement"]["position"] == %{"x" => 300, "y" => 160}
      assert stages["security"]["position"] == %{"x" => 520, "y" => 160}
      assert stages["blocked"]["position"] == %{"x" => 300, "y" => 40}
      assert stages["review"]["position"]["y"] == 160
      assert stages["done"]["position"]["x"] > stages["review"]["position"]["x"]
      assert stages["orphan"]["position"]["x"] == stages["done"]["position"]["x"]

      assert suggestion.changes.added == ["Security", "Orphan"]
      assert suggestion.changes.removed |> Enum.sort() == ["Merge", "Rework"]
      assert "Build" in suggestion.changes.changed
    end

    test "flows: an invalid draft gets one repair round, then a plain error", %{bin: bin, definition: definition} do
      bad = Jason.encode!(%{"stages" => [%{"id" => "x", "name" => "X", "kind" => "agent", "linear_state" => "Todo"}], "transitions" => []})
      counter = Path.join(bin, "calls")

      fake(bin, "claude", """
      n=$(cat #{counter} 2>/dev/null || echo 0); echo $((n+1)) > #{counter}
      if [ "$n" = "0" ]; then printf '%s' '#{bad}'; else printf '%s' '#{Jason.encode!(@flow)}'; fi
      """)

      assert {:ok, %{definition: %{"stages" => [_ | _]}}} = Assistant.draft_flow(definition, "Add security.", harness: "claude")
      assert File.read!(counter) == "2\n"

      fake(bin, "claude", "printf '%s' '#{bad}'")
      assert {:error, "The assistant's flow still had problems: a factory needs a done stage" <> _} = Assistant.draft_flow(definition, "x", harness: "claude")

      assert {:error, "Describe the flow you want."} = Assistant.draft_flow(definition, " ")
    end

    test "flows: the prompt describes the scope, states, and current flow", %{definition: definition} do
      opts = [scope_label: "the PAY team", linear_states: ["Todo", "QA"], label_prefix: "line", skills: false]
      prompt = Assistant.build_flow_prompt(definition, "Ship faster.", opts)
      assert prompt =~ "AI software factory for the PAY team"
      assert prompt =~ "Linear states known to exist: Todo, QA."
      assert prompt =~ "`line/<label>`"
      assert prompt =~ "- review -> merge (human): The reviewer approves the PR"
      assert prompt =~ ~s(Set every "skill" to null.)
      assert Assistant.build_flow_prompt(definition, "x", []) =~ "Use the standard Linear states"
    end

    test "flows: an unchanged stage set keeps its positions", %{definition: definition} do
      moved = %{definition | "stages" => Enum.map(definition["stages"], &Map.put(&1, "position", %{"x" => 1, "y" => 2}))}
      assert Enum.all?(Assistant.layout(definition, moved)["stages"], &(&1["position"] == %{"x" => 1, "y" => 2}))

      # A flow with no start (everything has an incoming connection) starts from its first stage.
      stages = [%{"id" => "a", "kind" => "agent"}, %{"id" => "b", "kind" => "done"}]
      loop = %{"stages" => stages, "transitions" => [%{"from" => "a", "to" => "b"}, %{"from" => "b", "to" => "a"}]}
      assert [%{"position" => %{"x" => 80}}, %{"position" => %{"x" => 300}}] = Assistant.layout(loop)["stages"]

      # Done is the start: the agent stage hangs below it.
      cut = %{loop | "transitions" => [%{"from" => "b", "to" => "a"}]}
      assert [%{"position" => %{"x" => 80, "y" => 280}}, %{"position" => %{"x" => 80, "y" => 160}}] = Assistant.layout(cut)["stages"]

      # Nothing reaches done: the start alone is the spine and done sits under it.
      apart = %{"stages" => [%{"id" => "q", "kind" => "queue"}, %{"id" => "d", "kind" => "done"}], "transitions" => []}
      assert [%{"position" => %{"x" => 80, "y" => 160}}, %{"position" => %{"x" => 80, "y" => 280}}] = Assistant.layout(apart)["stages"]

      # Waiting stages sharing a column stack upward, and the flow shifts down to fit.
      stacked = %{
        "stages" => [%{"id" => "q", "kind" => "queue"}, %{"id" => "d", "kind" => "done"}, %{"id" => "p1", "kind" => "parked"}, %{"id" => "p2", "kind" => "human"}],
        "transitions" => [%{"from" => "q", "to" => "d"}, %{"from" => "q", "to" => "p1"}, %{"from" => "q", "to" => "p2"}]
      }

      assert Enum.map(Assistant.layout(stacked)["stages"], &{&1["id"], &1["position"]}) == [
               {"q", %{"x" => 80, "y" => 280}},
               {"d", %{"x" => 300, "y" => 280}},
               {"p1", %{"x" => 80, "y" => 160}},
               {"p2", %{"x" => 80, "y" => 40}}
             ]

      # Two branches meeting again: the spine takes one, the other hangs below.
      diamond = %{
        "stages" => Enum.map([{"q", "queue"}, {"a", "agent"}, {"b", "agent"}, {"c", "agent"}, {"d", "done"}], fn {id, kind} -> %{"id" => id, "kind" => kind} end),
        "transitions" => Enum.map([{"q", "a"}, {"q", "b"}, {"a", "c"}, {"b", "c"}, {"c", "d"}], fn {from, to} -> %{"from" => from, "to" => to} end)
      }

      assert %{"a" => %{"y" => 160}, "b" => %{"x" => 300, "y" => 280}, "c" => %{"x" => 520}, "d" => %{"x" => 740}} =
               Map.new(Assistant.layout(diamond)["stages"], &{&1["id"], &1["position"]})
    end

    test "escaped quotes and braces inside JSON strings don't end the object early" do
      assert {:ok, %{"instructions" => ~S(say "hi" {x})}} = Assistant.parse(~S(ok {"instructions": "say \"hi\" {x}"} trailing))
    end
  end
end
