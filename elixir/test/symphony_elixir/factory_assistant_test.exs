defmodule SymphonyElixir.FactoryAssistantTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Factory.{Assistant, Definition}

  test "parses claude's JSON wrapper, fenced JSON, and prose around the object" do
    draft = %{"instructions" => "Run e2e.", "transitions" => [], "skill" => nil}
    wrapped = Jason.encode!(%{"type" => "result", "result" => "Here you go:\n```json\n" <> Jason.encode!(draft) <> "\n```"})

    assert {:ok, ^draft} = Assistant.parse(wrapped)
    assert {:ok, ^draft} = Assistant.parse("Sure! " <> Jason.encode!(draft) <> " Hope that helps {not json}")
    assert {:ok, %{"instructions" => "a } b"}} = Assistant.parse(~s({"instructions": "a } b"}))
    assert {:error, _} = Assistant.parse("I can't help with that.")
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
    assert {:error, "Keep the description under 2,000 characters."} = Assistant.draft(definition, "merge", String.duplicate("a", 2_001))
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

    test "escaped quotes and braces inside JSON strings don't end the object early" do
      assert {:ok, %{"instructions" => ~S(say "hi" {x})}} = Assistant.parse(~S(ok {"instructions": "say \"hi\" {x}"} trailing))
    end
  end
end
