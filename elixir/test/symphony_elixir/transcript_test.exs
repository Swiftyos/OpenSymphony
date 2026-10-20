defmodule SymphonyElixir.TranscriptTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Transcript

  setup do
    Transcript.reset()
    on_exit(&Transcript.reset/0)
    :ok
  end

  defp codex(item), do: %{event: :notification, payload: %{"method" => "item/completed", "params" => %{"item" => item}}}
  defp part(part), do: %{event: "message.part.updated", payload: %{"payload" => %{"type" => "message.part.updated", "properties" => %{"part" => part}}}}

  test "Codex items become readable entries; streaming noise is skipped" do
    Transcript.record("PAY-1", codex(%{"type" => "agentMessage", "text" => "Reading the spec."}))
    Transcript.record("PAY-1", codex(%{"type" => "commandExecution", "command" => "go test ./...", "exitCode" => 1, "aggregatedOutput" => "FAIL x\n"}))
    Transcript.record("PAY-1", codex(%{"type" => "commandExecution", "command" => ["ls"], "aggregatedOutput" => ""}))
    Transcript.record("PAY-1", codex(%{"type" => "fileChange", "changes" => [%{"path" => "a.go"}, %{}]}))
    Transcript.record("PAY-1", codex(%{"type" => "reasoning", "summary" => [%{"text" => "Plan it"}, "then build", 3]}))
    Transcript.record("PAY-1", codex(%{"type" => "reasoning", "summary" => []}))
    Transcript.record("PAY-1", codex(%{"type" => "mcpToolCall", "server" => "linear", "tool" => "save_issue"}))
    Transcript.record("PAY-1", codex(%{"type" => "dynamicToolCall", "tool" => "linear_graphql"}))
    Transcript.record("PAY-1", codex(%{"type" => "dynamicToolCall"}))
    Transcript.record("PAY-1", codex(%{"type" => "webSearch", "query" => "monday api"}))
    Transcript.record("PAY-1", codex(%{"type" => "agentMessage", "text" => ""}))
    Transcript.record("PAY-1", codex(%{"type" => "userMessage"}))
    Transcript.record("PAY-1", %{event: :notification, payload: %{"method" => "item/agentMessage/delta"}})
    Transcript.record("PAY-1", %{event: :notification, payload: Jason.encode!(%{"method" => "turn/failed", "params" => %{"error" => "boom"}})})
    Transcript.record("PAY-1", %{event: :x, raw: "not json"})
    Transcript.record("PAY-1", %{event: :x})

    assert Enum.map(Transcript.entries("PAY-1"), &{&1.kind, &1.text}) == [
             {"agent", "Reading the spec."},
             {"tool", "$ go test ./... (exit 1)\nFAIL x"},
             {"tool", "$ ls"},
             {"tool", "Edited a.go, a file"},
             {"thinking", "Plan it\nthen build"},
             {"tool", "linear/save_issue"},
             {"tool", "linear_graphql"},
             {"tool", "tool"},
             {"tool", "Searched the web: monday api"},
             {"error", ~s(Turn failed: "boom")}
           ]
  end

  test "Claude Code and OpenCode parts, and Symphony's own notes" do
    Transcript.record("PAY-2", part(%{"type" => "text", "text" => "Planning."}))
    Transcript.record("PAY-2", part(%{"type" => "reasoning", "text" => "Hmm"}))
    Transcript.record("PAY-2", part(%{"type" => "tool", "tool" => "Bash", "input" => ~s({"command":"ls"})}))
    Transcript.record("PAY-2", part(%{"type" => "tool", "tool" => "Read", "input" => "{}"}))
    Transcript.record("PAY-2", part(%{"type" => "tool", "tool" => "Edit", "state" => %{"input" => "x"}}))
    Transcript.record("PAY-2", part(%{"type" => "step-start"}))
    Transcript.record("PAY-2", %{raw: Jason.encode!(%{"payload" => %{"type" => "message.part.updated", "properties" => %{"part" => %{"type" => "text", "text" => "raw"}}}})})
    Transcript.note("PAY-2", "Symphony moved the issue to Implement.")

    assert Enum.map(Transcript.entries("PAY-2"), &{&1.kind, &1.text}) == [
             {"agent", "Planning."},
             {"thinking", "Hmm"},
             {"tool", ~s(Bash {"command":"ls"})},
             {"tool", "Read"},
             {"tool", "Edit x"},
             {"agent", "raw"},
             {"symphony", "Symphony moved the issue to Implement."}
           ]
  end

  test "long output keeps its end, entries are capped, and bad input is ignored" do
    Transcript.record("PAY-3", %{
      event: :notification,
      payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "commandExecution", "command" => "x", "aggregatedOutput" => String.duplicate("a", 2_000) <> "END"}}}
    })

    assert [%{text: "$ x\n…" <> rest}] = Transcript.entries("PAY-3")
    assert String.ends_with?(rest, "END")

    for n <- 1..410, do: Transcript.note("PAY-4", "n#{n}")
    entries = Transcript.entries("PAY-4")
    assert length(entries) == 400
    assert hd(entries).text == "n11"

    assert Transcript.record(nil, %{}) == :ok
    assert Transcript.note(nil, "x") == :ok
    assert Transcript.entries(nil) == []
    assert Transcript.entries("NONE-1") == []
  end

  test "without the table everything is a no-op" do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Transcript)
    on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, Transcript) end)

    assert Transcript.note("PAY-5", "x") == :ok
    assert Transcript.entries("PAY-5") == []
    assert Transcript.reset() == :ok
  end
end
