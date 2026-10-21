defmodule SymphonyElixir.DashboardComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SymphonyElixirWeb.{Charts, ChatPanel, Markdown}

  defp md(text), do: text |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()

  describe "Markdown" do
    test "renders the subset agents use and escapes everything else" do
      html =
        md("""
        ## Plan
        Fixed **the route** so `/a<b>` resolves, *quietly*.
        See [the PR](https://github.com/acme/gadgets/pull/1) and [bad](javascript:alert(1)).

        - one
        - two

        1. first
        2. second

        > quoted
        > twice

        ```go
        if a < b { return }
        ```
        <script>alert(1)</script>
        """)

      assert html =~ "<h4>Plan</h4>"
      assert html =~ "<strong>the route</strong>"
      assert html =~ "<code>/a&lt;b&gt;</code>"
      assert html =~ "<em>quietly</em>"
      assert html =~ ~s(<a href="https://github.com/acme/gadgets/pull/1" target="_blank" rel="noopener noreferrer">the PR</a>)
      refute html =~ "javascript:alert(1)\""
      assert html =~ "<ul><li>one</li><li>two</li></ul>"
      assert html =~ "<ol><li>first</li><li>second</li></ol>"
      assert html =~ "<blockquote>quoted<br>twice</blockquote>"
      assert html =~ ~s(<pre class="md-code" data-lang="go"><code>if a &lt; b { return }</code></pre>)
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>"
    end

    test "an unterminated fence still renders as code, and nil is empty" do
      assert md("```\nopen") == ~s(<pre class="md-code"><code>open</code></pre>)
      assert md(nil) == ""
    end
  end

  describe "ChatPanel" do
    @at ~U[2026-10-20 21:05:00Z]

    test "draws each kind of transcript entry, new and old shapes" do
      entries = [
        %{id: "1", at: @at, kind: "turn", title: "Turn 2 · implement", text: "Turn 2"},
        %{id: "2", at: @at, kind: "user", text: "Run the **smoke** test", author: "Ada", status: "queued"},
        %{id: "3", at: @at, kind: "user", text: "And lint", author: "Ada", status: "delivered", delivery: "steered"},
        %{id: "4", at: @at, kind: "user", text: "Later", author: nil, status: "delivered", delivery: "next_turn"},
        %{id: "4b", at: "earlier", kind: "user", text: "Odd", author: nil, status: "failed"},
        %{id: "5", at: @at, kind: "agent", text: "Done: `go test` passes"},
        %{id: "6", at: @at, kind: "thinking", text: "Look at the route table"},
        %{id: "7", at: @at, kind: "command", command: "go test ./...", body: "FAIL", exit_code: 1, duration_ms: 1500, status: "failed"},
        %{id: "8", at: @at, kind: "command", command: "make lint", body: "", status: "running", duration_ms: 90_000},
        %{id: "9", at: @at, kind: "command", command: "ls", body: "a", exit_code: 0, duration_ms: 40},
        %{
          id: "10",
          at: @at,
          kind: "edit",
          files: [%{path: "lib/a.ex", additions: 2, deletions: 1, diff: "--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n same"}, "lib/b.ex"]
        },
        %{id: "11", at: @at, kind: "edit", files: [], title: "lib/c.ex"},
        %{id: "12", at: @at, kind: "tool", tool: "linear_graphql", title: "linear_graphql", body: "{}", status: "completed"},
        %{id: "13", at: @at, kind: "tool", text: "$ mix test (exit 2)\n1 failure"},
        %{id: "14", at: @at, kind: "tool", text: "$ echo hi\nhi"},
        %{id: "15", at: @at, kind: "tool", text: "Edited a.ex, b.ex"},
        %{id: "16", at: @at, kind: "tool", text: "server/tool\nresult"},
        %{id: "17", at: @at, kind: "tool", text: "server/tool"},
        %{id: "18", at: @at, kind: "symphony", text: "Moved to Review"},
        %{id: "19", at: @at, kind: "error", text: "Turn failed"},
        %{id: "20", at: nil, kind: "mystery", text: "?"}
      ]

      session = %{
        issue_title: "Jira",
        stage: "Implement",
        turn_count: 2,
        backend: "codex",
        model: "deepseek",
        effort: "medium",
        issue_url: "https://linear.app/x"
      }

      html =
        render_component(&ChatPanel.chat_panel/1,
          issue: "TRUST-1",
          entries: entries,
          session: session,
          can_message: true,
          error: "Write a message first.",
          expanded: true
        )

      assert html =~ "Turn 2 · implement"
      assert html =~ "queued for the agent"
      assert html =~ "delivered mid-turn"
      assert html =~ "delivered at turn start"
      assert html =~ "· failed"
      assert html =~ "<strong>smoke</strong>"
      assert html =~ "Thought"
      assert html =~ "exit 1 · 1.5s"
      assert html =~ "1m 30s"
      assert html =~ "40ms"
      assert html =~ "is-running"
      assert html =~ "Edited 2 files"
      assert html =~ ~s(class="d-add")
      assert html =~ ~s(class="d-del")
      assert html =~ ~s(class="d-hunk")
      assert html =~ ~s(class="d-file")
      assert html =~ "Edited 1 file"
      assert html =~ "linear_graphql"
      assert html =~ "exit 2"
      assert html =~ "server/tool"
      assert html =~ "Moved to Review"
      assert html =~ "Turn failed"
      assert html =~ "mystery"
      assert html =~ "Working"
      assert html =~ "Write a message first."
      assert html =~ "chat-compose-TRUST-1"
      assert html =~ "is-expanded"
    end

    test "an idle issue the viewer can't message" do
      html = render_component(&ChatPanel.chat_panel/1, issue: "TRUST-2", entries: [], can_message: false)

      assert html =~ "Idle"
      assert html =~ "Nothing yet"
      assert html =~ "can read this conversation but not message"
      refute html =~ "chat-compose"
    end
  end

  describe "Charts" do
    test "stacked bars, bar lists, and a waterfall" do
      points = [
        %{at: ~U[2026-10-20 20:00:00Z], values: %{"claude" => 2, "codex" => 1_500_000_000, "other" => nil}},
        %{at: "now", values: %{"codex" => 0}}
      ]

      bars = render_component(&Charts.stacked_bars/1, points: points, label: "Tokens")
      assert bars =~ "chart-bar h-codex"
      assert bars =~ "peak 1.5B"
      assert bars =~ "20 Oct 20:00"

      empty = render_component(&Charts.stacked_bars/1, points: [%{at: nil, values: %{}}], label: "None", format: &Charts.money/1)
      assert empty =~ "peak $0.00"

      rows = [%{label: "TRUST-1", value: 12_000, href: "/insights?issue=TRUST-1"}, %{label: "Bash", value: nil}]
      list = render_component(&Charts.bar_list/1, rows: rows)
      assert list =~ ~s(href="/insights?issue=TRUST-1")
      assert list =~ "12k"
      assert render_component(&Charts.bar_list/1, rows: [], empty: "Nothing here") =~ "Nothing here"

      spans = [
        %{id: "r", parent_id: nil, name: "turn", start_ms: 0, duration_ms: 7_200_000},
        %{id: "c", parent_id: "r", name: "exec", start_ms: 10, duration_ms: 65_000, status: "error", detail: "boom"},
        %{id: "o", parent_id: "gone", name: "orphan", start_ms: nil, duration_ms: nil}
      ]

      waterfall = render_component(&Charts.waterfall/1, spans: spans)
      assert waterfall =~ "padding-left: 14px"
      assert waterfall =~ "is-error"
      assert waterfall =~ "2h"
      assert waterfall =~ "1.1m"

      flat = render_component(&Charts.bar_list/1, rows: [%{label: "none", value: nil}])
      assert flat =~ "width: 0%"
    end

    test "number formats" do
      assert Charts.compact(nil) == "0"
      assert Charts.compact(2_500_000) == "2.5M"
      assert Charts.compact(1_000) == "1k"
      assert Charts.compact(1.25) == "1.3"
      assert Charts.compact(7) == "7"
      assert Charts.money(nil) == "$0"
      assert Charts.money(250.4) == "$250"
      assert Charts.money(3) == "$3.00"
      assert Charts.ms(nil) == "–"
      assert Charts.ms(3_600_000) == "1h"
      assert Charts.ms(1500) == "1.5s"
      assert Charts.ms(12.4) == "12ms"
    end
  end
end
