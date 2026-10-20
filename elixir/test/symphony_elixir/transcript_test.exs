defmodule SymphonyElixir.TranscriptTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Transcript

  setup do
    Transcript.reset()
    on_exit(&Transcript.reset/0)
    :ok
  end

  defp codex(item, method \\ "item/completed"),
    do: %{event: :notification, payload: %{"method" => method, "params" => %{"item" => item}}}

  defp part(part),
    do: %{event: "message.part.updated", payload: %{"payload" => %{"type" => "message.part.updated", "properties" => %{"part" => part}}}}

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
             {"command", "$ go test ./... (exit 1)\nFAIL x"},
             {"command", "$ ls"},
             {"edit", "Edited a.go, a file"},
             {"thinking", "Plan it\nthen build"},
             {"tool", "linear/save_issue"},
             {"tool", "linear_graphql"},
             {"tool", "tool"},
             {"tool", "Searched the web: monday api"},
             {"error", ~s(Turn failed: "boom")}
           ]
  end

  test "Codex commands and file changes carry structured fields, updated in place" do
    started = %{"type" => "commandExecution", "id" => "c1", "command" => "mix test", "status" => "inProgress", "aggregatedOutput" => nil}
    Transcript.record("PAY-6", codex(started, "item/started"), backend: "codex")
    assert [%{kind: "command", status: "running", exit_code: nil, title: "Ran mix test", backend: "codex"}] = Transcript.entries("PAY-6")

    done = %{started | "status" => "completed", "aggregatedOutput" => "3 tests, 0 failures\n"} |> Map.merge(%{"exitCode" => 0, "durationMs" => 1200})
    Transcript.record("PAY-6", codex(done), backend: "codex")

    assert [command] = Transcript.entries("PAY-6")

    assert %{kind: "command", command: "mix test", exit_code: 0, duration_ms: 1200, status: "completed", body: "3 tests, 0 failures"} =
             command

    assert command.text == "$ mix test (exit 0)\n3 tests, 0 failures"
    assert is_binary(command.id)

    changes = [
      %{"path" => "lib/a.ex", "kind" => %{"type" => "update", "move_path" => nil}, "diff" => "@@ -1,2 +1,2 @@\n-old\n+new\n+more\n context"},
      %{"path" => "lib/b.ex", "kind" => %{"type" => "add"}, "diff" => "line 1\nline 2\n"},
      %{"path" => "lib/c.ex", "kind" => "delete", "diff" => "gone\n"}
    ]

    Transcript.record("PAY-6", codex(%{"type" => "fileChange", "id" => "f1", "status" => "completed", "changes" => changes}))

    assert [_, %{kind: "edit", title: "Edited 3 files", status: "completed", files: files, text: text}] = Transcript.entries("PAY-6")
    assert text == "Edited lib/a.ex, lib/b.ex, lib/c.ex"

    assert [
             %{path: "lib/a.ex", kind: "update", additions: 2, deletions: 1},
             %{path: "lib/b.ex", kind: "add", additions: 2, deletions: 0},
             %{path: "lib/c.ex", kind: "delete", additions: 0, deletions: 1}
           ] = files

    assert hd(files).diff =~ "+new"

    mcp = %{
      "type" => "mcpToolCall",
      "id" => "m1",
      "server" => "linear",
      "tool" => "get_issue",
      "arguments" => %{"id" => "PAY-6"},
      "result" => %{"content" => [%{"type" => "text", "text" => "Issue body"}]},
      "status" => "completed",
      "durationMs" => 40
    }

    Transcript.record("PAY-6", codex(mcp))
    Transcript.record("PAY-6", codex(%{"type" => "mcpToolCall", "server" => "x", "tool" => "y", "error" => %{"message" => "denied"}, "status" => "failed"}))
    Transcript.record("PAY-6", codex(%{"type" => "dynamicToolCall", "tool" => "t", "success" => false, "contentItems" => [%{"text" => "bad"}]}))
    Transcript.record("PAY-6", codex(%{"type" => "reasoning", "summary" => [], "content" => ["raw thought"]}))

    assert [_, _, mcp_entry, failed, dynamic, thinking] = Transcript.entries("PAY-6")
    assert %{kind: "tool", tool: "linear/get_issue", status: "completed", duration_ms: 40} = mcp_entry
    assert mcp_entry.body =~ ~s("id": "PAY-6")
    assert mcp_entry.body =~ "Issue body"
    assert %{status: "failed", body: "Error: denied"} = failed
    assert %{status: "failed", body: "bad"} = dynamic
    assert %{kind: "thinking", text: "raw thought"} = thinking
  end

  test "Claude Code parts: thinking, commands paired with their results, edits, other tools" do
    Transcript.record("PAY-2", part(%{"type" => "text", "text" => "Planning."}), backend: "claude")
    Transcript.record("PAY-2", part(%{"type" => "reasoning", "text" => "Hmm"}))

    bash = %{"type" => "tool", "tool" => "Bash", "callID" => "tu1", "args" => %{"command" => "make test\nmore"}, "input" => ~s({"command":"make test"})}
    Transcript.record("PAY-2", part(bash))
    Transcript.record("PAY-2", part(%{"type" => "tool", "tool" => "Bash", "callID" => "tu2", "args" => %{"command" => "ls"}}))

    edit = %{"type" => "tool", "tool" => "Edit", "callID" => "tu3", "args" => %{"file_path" => "/w/a.ex", "old_string" => "a\nb", "new_string" => "c"}}
    Transcript.record("PAY-2", part(edit))

    multi = %{"file_path" => "b.ex", "edits" => [%{"old_string" => "x", "new_string" => "y\nz"}, %{"old_string" => "q", "new_string" => "r"}]}
    Transcript.record("PAY-2", part(%{"type" => "tool", "tool" => "MultiEdit", "callID" => "tu4", "args" => multi}))
    Transcript.record("PAY-2", part(%{"type" => "tool", "tool" => "Write", "callID" => "tu5", "args" => %{"file_path" => "new.ex", "content" => "1\n2\n3\n"}}))
    Transcript.record("PAY-2", part(%{"type" => "tool", "tool" => "Read", "callID" => "tu6", "args" => %{"file_path" => "README.md"}}))
    Transcript.record("PAY-2", part(%{"type" => "tool", "tool" => "mcp__linear__save_issue", "callID" => "tu7", "input" => ~s({"id":"PAY-2"})}))

    Transcript.record("PAY-2", part(%{"type" => "tool_result", "callID" => "tu1", "output" => "Exit code 2\nboom", "is_error" => true}))
    Transcript.record("PAY-2", part(%{"type" => "tool_result", "callID" => "tu2", "output" => "a\nb", "is_error" => false}))
    Transcript.record("PAY-2", part(%{"type" => "tool_result", "callID" => "tu6", "output" => [%{"type" => "text", "text" => "# Readme"}]}))
    Transcript.record("PAY-2", part(%{"type" => "tool_result", "callID" => "unknown", "output" => "orphan"}))
    Transcript.record("PAY-2", part(%{"type" => "step-start"}))
    Transcript.note("PAY-2", "Symphony moved the issue to Implement.")

    entries = Transcript.entries("PAY-2")
    assert [agent, thinking, failed_cmd, ok_cmd, edit_entry, multi, write_entry, read, mcp, orphan, note] = entries

    assert %{kind: "agent", text: "Planning.", backend: "claude"} = agent
    assert %{kind: "thinking", text: "Hmm"} = thinking

    assert %{kind: "command", command: "make test\nmore", title: "Ran make test", exit_code: 2, status: "failed", body: "boom"} =
             failed_cmd

    assert %{kind: "command", exit_code: 0, status: "completed", body: "a\nb", text: "$ ls (exit 0)\na\nb"} = ok_cmd

    assert %{kind: "edit", title: "Edited /w/a.ex", files: [%{path: "/w/a.ex", additions: 1, deletions: 2, kind: "update"}]} = edit_entry
    assert %{files: [%{path: "b.ex", additions: 3, deletions: 2}]} = multi
    assert %{files: [%{path: "new.ex", additions: 3, kind: "write"}]} = write_entry
    assert %{kind: "tool", title: "Read README.md", status: "completed", body: body} = read
    assert body =~ "# Readme"
    assert %{kind: "tool", title: "linear/save_issue", tool: "mcp__linear__save_issue"} = mcp
    assert %{kind: "tool", body: "orphan"} = orphan
    assert %{kind: "symphony"} = note
  end

  test "OpenCode parts update in place as they stream" do
    Transcript.record("PAY-7", part(%{"type" => "text", "id" => "p1", "text" => "Work"}))
    Transcript.record("PAY-7", part(%{"type" => "text", "id" => "p1", "text" => "Working on it"}))

    running = %{"type" => "tool", "id" => "p2", "tool" => "bash", "state" => %{"status" => "running", "input" => %{"command" => "go vet"}}}
    Transcript.record("PAY-7", part(running))

    done = put_in(running, ["state"], %{"status" => "completed", "input" => %{"command" => "go vet"}, "output" => "ok", "metadata" => %{"exit" => 0}})
    Transcript.record("PAY-7", part(done))

    patch = "*** Begin Patch\n*** Update File: a.go\n@@\n*** Add File: b.go\n*** End Patch"
    Transcript.record("PAY-7", part(%{"type" => "tool", "id" => "p3", "tool" => "patch", "state" => %{"status" => "error", "input" => %{"patchText" => patch}, "error" => "nope"}}))
    Transcript.record("PAY-7", part(%{"type" => "tool", "tool" => "Edit", "state" => %{"input" => "x"}}))
    Transcript.record("PAY-7", %{raw: Jason.encode!(%{"payload" => %{"type" => "message.part.updated", "properties" => %{"part" => %{"type" => "text", "text" => "raw"}}}})})

    assert [text, command, patch_entry, edit, raw] = Transcript.entries("PAY-7")
    assert text.text == "Working on it"
    assert %{kind: "command", status: "completed", exit_code: 0, body: "ok"} = command
    assert %{kind: "edit", status: "failed", files: [%{path: "a.go", kind: "update"}, %{path: "b.go", kind: "add"}]} = patch_entry
    assert patch_entry.text == "Edited a.go, b.go (failed)"
    assert %{kind: "edit", files: [%{path: "a file"}]} = edit
    assert raw.text == "raw"
  end

  test "turn markers and dashboard messages" do
    Transcript.turn_started("PAY-8", %{turn: 2, stage: "implement", backend: "codex"})
    Transcript.turn_started("PAY-8", %{turn: 3})
    Transcript.user_message("PAY-8", %{id: "msg_1", text: "Use the v2 API", author: "Mia", status: "queued", delivery: nil})
    Transcript.message_delivered("PAY-8", %{id: "msg_1", status: "delivered", delivery: "steered"})
    Transcript.message_delivered("PAY-8", %{id: "msg_missing", status: "delivered", delivery: "steered"})

    assert [turn, turn3, user] = Transcript.entries("PAY-8")
    assert %{kind: "turn", text: "Turn 2 · implement", title: "Turn 2 · implement", turn: 2, stage: "implement", backend: "codex"} = turn
    assert turn3.text == "Turn 3"
    assert %{kind: "user", text: "Use the v2 API", author: "Mia", status: "delivered", delivery: "steered", message_id: "msg_1"} = user

    assert Transcript.turn_started(nil, %{turn: 1}) == :ok
    assert Transcript.user_message(nil, %{}) == :ok
    assert Transcript.message_delivered(nil, %{}) == :ok
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
