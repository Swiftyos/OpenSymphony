defmodule SymphonyElixir.AgentMetricsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.{AgentMetrics, RunEvents, RunHost, RunToken, SessionHistory, Transcript, UsageLedger}
  alias SymphonyElixir.Capacity.{Metrics, Prometheus}
  alias SymphonyElixir.RunHost.Local
  alias SymphonyElixir.RunnerTestSupport, as: Support

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    Metrics.reset()
    Transcript.reset()
    on_exit(fn -> Transcript.reset() end)
    :ok
  end

  defp counters do
    for %{name: name, labels: labels, value: value} <- Metrics.snapshot().counters,
        String.starts_with?(name, "symphony_agent_"),
        into: %{},
        do: {{name, Map.new(labels)}, value}
  end

  defp codex_item(item), do: %{event: :notification, payload: %{"method" => "item/completed", "params" => %{"item" => item}}}

  defp codex_started(item), do: %{event: :notification, payload: %{"method" => "item/started", "params" => %{"item" => item}}}

  defp part(part), do: %{event: "message.part.updated", payload: %{"payload" => %{"type" => "message.part.updated", "properties" => %{"part" => part}}}}

  # One run's worth of agent events, for every backend's shapes.
  defp events do
    [
      {"codex", codex_started(%{"type" => "commandExecution", "id" => "c1", "command" => ["ls"], "status" => "inProgress"})},
      {"codex", codex_item(%{"type" => "commandExecution", "id" => "c1", "command" => ["ls"], "status" => "completed", "exitCode" => 0})},
      {"codex", codex_item(%{"type" => "commandExecution", "id" => "c2", "command" => ["false"], "status" => "failed", "exitCode" => 1})},
      {"codex", codex_item(%{"type" => "fileChange", "id" => "f1", "changes" => [%{"path" => "a.ex", "diff" => "+x"}], "status" => "completed"})},
      {"codex", codex_item(%{"type" => "mcpToolCall", "id" => "m1", "server" => "linear", "tool" => "get", "status" => "completed"})},
      {"codex", codex_item(%{"type" => "dynamicToolCall", "id" => "d1", "tool" => "linear_graphql", "success" => false})},
      {"codex", codex_item(%{"type" => "agentMessage", "text" => "done"})},
      # Claude Code: the tool_use is running; its result ends it.
      {"claude", part(%{"type" => "tool", "tool" => "Bash", "callID" => "t1", "state" => %{"status" => "running"}})},
      {"claude", part(%{"type" => "tool_result", "callID" => "t1", "output" => "ok", "is_error" => false})},
      {"claude", part(%{"type" => "tool_result", "callID" => "t2", "output" => "no", "is_error" => true})},
      # OpenCode updates a tool part in place until it completes.
      {"opencode", part(%{"type" => "tool", "tool" => "read", "id" => "o1", "state" => %{"status" => "pending"}})},
      {"opencode", part(%{"type" => "tool", "tool" => "read", "id" => "o1", "state" => %{"status" => "completed", "output" => "x"}})},
      {"opencode", part(%{"type" => "tool", "tool" => "edit", "id" => "o2", "state" => %{"status" => "error", "error" => "x"}})},
      {"opencode", %{event: :turn_completed, payload: "not json"}}
    ]
  end

  defp expected_tool_calls do
    %{
      {"symphony_agent_tool_calls_total", %{"backend" => "codex", "outcome" => "ok"}} => 3,
      {"symphony_agent_tool_calls_total", %{"backend" => "codex", "outcome" => "error"}} => 2,
      {"symphony_agent_tool_calls_total", %{"backend" => "claude", "outcome" => "ok"}} => 1,
      {"symphony_agent_tool_calls_total", %{"backend" => "claude", "outcome" => "error"}} => 1,
      {"symphony_agent_tool_calls_total", %{"backend" => "opencode", "outcome" => "ok"}} => 1,
      {"symphony_agent_tool_calls_total", %{"backend" => "opencode", "outcome" => "error"}} => 1,
      {"symphony_agent_turns_total", %{"backend" => "codex"}} => 2,
      {"symphony_agent_turns_total", %{"backend" => "claude"}} => 1
    }
  end

  defp turns, do: [%{turn: 1, backend: "codex"}, %{turn: 2, backend: "codex"}, %{turn: 1, backend: "claude"}, %{turn: nil}]

  test "counts finished tool calls by backend and outcome, and turns, for an in-process run" do
    host = Local.new(nil)
    issue = %Issue{id: "issue-local", identifier: "MT-AM-1"}

    for {backend, message} <- events(), do: RunHost.agent_update(host, issue, backend, message)
    for info <- turns(), do: RunHost.turn_started(host, "MT-AM-1", info)

    assert counters() == expected_tool_calls()
  end

  describe "a runner-hosted run" do
    setup do
      root = Support.temp_root!("agent-metrics")
      Support.setup_runs!(root)
      Support.start_endpoint!()
      Support.record_run!("issue-remote", "run-am", identifier: "MT-AM-2", backend: "codex")
      :ok
    end

    test "counts the same events arriving over /runner/v1 exactly as an in-process run, once each" do
      updates =
        for {backend, message} <- events() do
          {"agent_update", %{issue_id: "issue-remote", identifier: "MT-AM-2", backend: backend, message: message}}
        end

      turn_events = for info <- turns(), do: {"turn_started", %{identifier: "MT-AM-2", info: info}}

      batch =
        (updates ++ turn_events)
        |> Enum.with_index(1)
        |> Enum.map(fn {{type, data}, seq} -> %{"seq" => seq, "type" => type, "data" => RunEvents.encode(data)} end)

      post = fn ->
        build_conn()
        |> put_req_header("authorization", "Bearer " <> RunToken.sign("run-am", 1))
        |> put_req_header("content-type", "application/json")
        |> post("/runner/v1/runs/run-am/events", Jason.encode!(%{"events" => batch}))
      end

      assert %{status: 200} = post.()
      assert counters() == expected_tool_calls()

      # A replayed outbox is deduplicated before anything is counted.
      assert %{status: 200} = post.()
      assert counters() == expected_tool_calls()
    end
  end

  test "token deltas are counted by backend and type where the usage ledger records them" do
    issue = %Issue{id: "issue-tokens", identifier: "MT-AM-3", title: "t", state: "In Progress"}
    delta = %{input_tokens: 100, output_tokens: 20, cached_input_tokens: 60}
    UsageLedger.record_tokens(%{issue: issue, backend: "claude"}, delta)
    UsageLedger.record_tokens(%{issue: issue, backend: "claude"}, %{input_tokens: 0, output_tokens: 0})
    AgentMetrics.tokens("mystery", %{input_tokens: 5, output_tokens: 0})
    AgentMetrics.tokens(nil, :nope)

    assert counters() == %{
             {"symphony_agent_tokens_total", %{"backend" => "claude", "type" => "input"}} => 100,
             {"symphony_agent_tokens_total", %{"backend" => "claude", "type" => "output"}} => 20,
             {"symphony_agent_tokens_total", %{"backend" => "claude", "type" => "cached_input"}} => 60,
             {"symphony_agent_tokens_total", %{"backend" => "other", "type" => "input"}} => 5
           }
  end

  test "ended runs are counted with their duration by backend and outcome" do
    SessionHistory.record(%{issue_id: "i", identifier: "MT-AM-4", backend: "codex", runtime_seconds: 90}, :finished)
    SessionHistory.record(%{issue_id: "i", identifier: "MT-AM-4", backend: "codex", runtime_seconds: 5_000}, :crashed)
    AgentMetrics.run_ended(%{backend: nil}, :surprise)
    AgentMetrics.run_ended(:nope, :finished)

    assert counters() == %{
             {"symphony_agent_runs_total", %{"backend" => "codex", "outcome" => "finished"}} => 1,
             {"symphony_agent_runs_total", %{"backend" => "codex", "outcome" => "crashed"}} => 1,
             {"symphony_agent_runs_total", %{"backend" => "unknown", "outcome" => "other"}} => 1
           }

    body = Prometheus.render()
    assert body =~ ~s(symphony_agent_run_duration_seconds_bucket{backend="codex",le="120",outcome="finished"} 1)
    assert body =~ ~s(symphony_agent_run_duration_seconds_bucket{backend="codex",le="3600",outcome="crashed"} 0)
    assert body =~ ~s(symphony_agent_run_duration_seconds_sum{backend="codex",outcome="crashed"} 5000)
  end

  test "malformed events are ignored" do
    assert :ok = AgentMetrics.tool_call(:nope, "codex")
    assert :ok = AgentMetrics.tool_call(%{payload: %{"payload" => %{"type" => "message.part.updated", "properties" => %{"part" => :bad}}}}, "codex")
    assert :ok = AgentMetrics.turn_started(nil)
    assert counters() == %{}
  end
end
