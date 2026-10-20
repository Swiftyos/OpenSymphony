defmodule SymphonyElixir.ObservabilityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Observability
  alias SymphonyElixir.Observability.{Cache, ClickHouse, Langfuse, Metrics}

  @trace_id "5830a0f648e6bed8741f0c99f4123d77"

  setup do
    Cache.clear()

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :observability_req_options)
      Cache.clear()
    end)

    :ok
  end

  defp configure!(observability_yaml, extra \\ "") do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
    #{extra}
    observability:
    #{observability_yaml}
    ---
    Prompt.
    """)

    SymphonyElixir.WorkflowStore.force_reload()
  end

  @clickhouse """
    clickhouse:
      url: http://ch.test:8123
      user: symphony
      password: $OBS_TEST_CH_PASSWORD
  """

  @langfuse """
    langfuse:
      url: http://lf.test:3000
      public_key: pk-test
      secret_key: sk-test
      public_url: https://langfuse.example.com/
  """

  defp stub!(responder) do
    parent = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, {:request, conn.host, conn.request_path, body, conn.query_params, Plug.Conn.get_req_header(conn, "authorization")})

      case responder.(conn.host, conn.request_path, body, conn.query_params) do
        {:json, data} -> Req.Test.json(conn, data)
        {:status, status, text} -> Plug.Conn.send_resp(conn, status, text)
        {:raw, text} -> Plug.Conn.send_resp(conn, 200, text)
        {:transport, reason} -> Req.Test.transport_error(conn, reason)
      end
    end

    Application.put_env(:symphony_elixir, :observability_req_options, plug: plug)
  end

  defp data(rows), do: {:json, %{"meta" => [], "data" => rows, "rows" => length(rows)}}

  @query_markers [
    {"SpanId AS span_id", :spans},
    {"AS ended_ms", :summary},
    {"TraceId AS trace_id, count()", :traces},
    {"'histogram' AS kind", :histogram},
    {"'quantiles' AS kind", :quantiles},
    {"AS at_ms", :logs},
    {"GROUP BY bucket, backend, model, measure", :series},
    {"GROUP BY backend, tool, measure", :tools}
  ]

  # Answers each ClickHouse query by what it selects. 64-bit integers come back
  # as strings, as they do for a readonly user.
  defp clickhouse_responder(overrides \\ %{}) do
    fn
      "ch.test", _path, body, _params ->
        kind = Enum.find_value(@query_markers, :breakdown, &marker_kind(&1, body))
        Map.get(overrides, kind, data(default_rows(kind)))

      "lf.test", "/api/public/projects", _body, _params ->
        {:json, %{"data" => [%{"id" => "proj-1", "name" => "factory"}]}}

      "lf.test", path, _body, _params ->
        Map.get(overrides, {:langfuse, path}, {:status, 404, "not found"})
    end
  end

  defp marker_kind({marker, kind}, body), do: if(body =~ marker, do: kind)

  defp default_rows(:breakdown) do
    [
      fact(%{"backend" => "claude", "issue" => "TRUST-1", "model" => "opus"}, "tokens_input", "100"),
      fact(%{"backend" => "claude", "issue" => "TRUST-1", "model" => "opus"}, "tokens_output", "50"),
      fact(%{"backend" => "claude", "issue" => "TRUST-1", "model" => "opus"}, "tokens_cache_read", "1000"),
      fact(%{"backend" => "claude", "issue" => "TRUST-1", "model" => "opus"}, "tokens_cache_creation", "10"),
      fact(%{"backend" => "claude", "issue" => "TRUST-1", "model" => "opus"}, "cost_usd", 1.5),
      fact(%{"backend" => "claude", "issue" => "TRUST-1", "model" => ""}, "tool_calls", 8),
      fact(%{"backend" => "claude", "issue" => "TRUST-1", "model" => ""}, "lines_added", 3),
      fact(%{"backend" => "claude", "issue" => "", "model" => ""}, "commits", 1),
      fact(%{"backend" => "codex", "issue" => "TRUST-2", "model" => "gpt"}, "tokens_input", "1000000"),
      fact(%{"backend" => "codex", "issue" => "TRUST-2", "model" => "gpt"}, "tokens_cache_read", "1000000"),
      fact(%{"backend" => "codex", "issue" => "TRUST-2", "model" => "gpt"}, "tokens_output", "1000000"),
      fact(%{"backend" => "codex", "issue" => "TRUST-2", "model" => "gpt"}, "api_requests", "40"),
      fact(%{"backend" => "codex", "issue" => "TRUST-2", "model" => "gpt"}, "api_errors", "1"),
      fact(%{"backend" => "codex", "issue" => "TRUST-2", "model" => "gpt"}, "turns", "3"),
      fact(%{"backend" => "codex", "issue" => "TRUST-2", "model" => "gpt"}, "tool_calls", "20"),
      fact(%{"backend" => "codex", "issue" => "TRUST-2", "model" => "gpt"}, "tool_errors", "2"),
      fact(%{"backend" => "codex", "issue" => "TRUST-2", "model" => "gpt"}, "unknown_measure", "2")
    ]
  end

  defp default_rows(:series) do
    now = System.os_time(:second)
    bucket = div(now, 3600) * 3600

    [
      fact(%{"bucket" => "#{bucket}", "backend" => "claude", "model" => "opus"}, "tokens_input", "10"),
      fact(%{"bucket" => "#{bucket}", "backend" => "claude", "model" => "opus"}, "cost_usd", 0.25),
      fact(%{"bucket" => "#{bucket}", "backend" => "codex", "model" => "gpt"}, "tool_calls", "4")
    ]
  end

  defp default_rows(:tools) do
    [
      fact(%{"backend" => "codex", "tool" => "exec_command"}, "tool_calls", "20"),
      fact(%{"backend" => "codex", "tool" => "exec_command"}, "tool_errors", "2"),
      fact(%{"backend" => "claude", "tool" => "Bash"}, "tool_calls", "8"),
      fact(%{"backend" => "claude", "tool" => ""}, "tool_calls", "1")
    ]
  end

  defp default_rows(:histogram) do
    [
      %{"backend" => "codex", "kind" => "histogram", "bounds" => [0, 100, 1000], "counts" => ["0", "50", "50", "0"]},
      %{"backend" => "codex", "kind" => "histogram", "bounds" => [0, 10], "counts" => ["0", "1", "0"]}
    ]
  end

  defp default_rows(:quantiles), do: [%{"backend" => "claude", "kind" => "quantiles", "q" => [4898.5, 33_790.4], "count" => "60"}]

  defp default_rows(:traces) do
    [
      %{
        "trace_id" => @trace_id,
        "span_count" => "35119",
        "started_ms" => "1792528820609",
        "duration_ms" => "836872",
        "root_name" => "turn/start",
        "service" => "codex-app-server",
        "backend" => "codex",
        "error_count" => "1"
      }
    ]
  end

  defp default_rows(:summary), do: [%{"span_count" => "3", "started_ms" => "1000", "ended_ms" => "1500", "error_count" => "1"}]

  defp default_rows(:spans) do
    [
      %{
        "span_id" => "b",
        "parent_span_id" => "a",
        "name" => "claude_code.llm_request",
        "service" => "claude-code",
        "kind" => "Internal",
        "start_us" => "1100000",
        "duration_ns" => "200000000",
        "status_code" => "Error",
        "status_message" => "boom",
        "attributes" => %{"model" => "opus", "input_tokens" => "12", "output_tokens" => "3", "cost_usd" => "0.01"}
      },
      %{
        "span_id" => "a",
        "parent_span_id" => "",
        "name" => "claude_code.interaction",
        "service" => "claude-code",
        "kind" => "Server",
        "start_us" => "1000000",
        "duration_ns" => "500000000",
        "status_code" => "Ok",
        "status_message" => "",
        "attributes" => %{"long" => String.duplicate("x", 900)}
      },
      %{
        "span_id" => "c",
        "parent_span_id" => "cut",
        "name" => "exec_command",
        "service" => "codex-app-server",
        "kind" => "",
        "start_us" => "1200000",
        "duration_ns" => "1000000",
        "status_code" => "Unset",
        "status_message" => "",
        "attributes" => nil
      }
    ]
  end

  defp default_rows(:logs) do
    [
      %{
        "at_ms" => "1792529654221",
        "event" => "claude_code.tool_result",
        "backend" => "claude",
        "trace_id" => "",
        "severity" => "INFO",
        "attributes" => %{"tool_name" => "Bash", "success" => "false", "duration_ms" => "40", "error_type" => "ShellError"}
      },
      %{
        "at_ms" => "1792529654000",
        "event" => "codex.tool_result",
        "backend" => "codex",
        "trace_id" => @trace_id,
        "severity" => "INFO",
        "attributes" => %{"tool_name" => "exec_command", "success" => "true", "nested" => %{"a" => 1}, "n" => 5}
      },
      %{"at_ms" => "1e20", "event" => "claude_code.api_error", "backend" => "claude", "trace_id" => "", "severity" => "", "attributes" => %{}}
    ]
  end

  defp fact(dims, measure, value), do: Map.merge(dims, %{"measure" => measure, "value" => value})

  describe "config" do
    test "observability sources are optional and default off" do
      {:ok, settings} = Schema.parse(%{})
      assert settings.observability.timeout_ms == 3_000
      assert settings.observability.cache_ttl_ms == 30_000
      assert settings.observability.clickhouse.url == nil
      assert settings.observability.clickhouse.database == "otel"
      assert settings.observability.langfuse.url == nil

      assert Config.observability_clickhouse() == nil
      assert Config.observability_langfuse() == nil
      assert Config.observability_cache_ttl_ms() == 30_000
      assert Observability.configured() == %{clickhouse: false, langfuse: false}
    end

    test "secrets resolve from $ENV_VAR references" do
      previous = System.get_env("OBS_TEST_CH_PASSWORD")
      System.put_env("OBS_TEST_CH_PASSWORD", "s3cret")
      System.put_env("OBS_TEST_LF_SECRET", "sk-env")

      on_exit(fn ->
        restore_env("OBS_TEST_CH_PASSWORD", previous)
        System.delete_env("OBS_TEST_LF_SECRET")
      end)

      configure!("""
        timeout_ms: 1500
        cache_ttl_ms: 0
        clickhouse:
          url: http://ch.test:8123
          user: symphony
          password: $OBS_TEST_CH_PASSWORD
          database: "  "
        langfuse:
          url: http://lf.test:3000
          public_key: pk
          secret_key: $OBS_TEST_LF_SECRET
          public_url: $OBS_TEST_UNSET_VAR
      """)

      assert Config.observability_clickhouse() == %{
               url: "http://ch.test:8123",
               user: "symphony",
               password: "s3cret",
               database: "otel",
               timeout_ms: 1500
             }

      assert %{secret_key: "sk-env", public_url: nil, timeout_ms: 1500} = Config.observability_langfuse()
      assert Config.observability_cache_ttl_ms() == 0
      assert Observability.configured() == %{clickhouse: true, langfuse: true}
    end

    test "langfuse needs both keys, and bad values are rejected" do
      configure!("""
        langfuse:
          url: http://lf.test:3000
          public_key: pk
          secret_key: $OBS_TEST_UNSET_VAR
      """)

      assert Config.observability_langfuse() == nil

      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"observability" => %{"timeout_ms" => 0}})
      assert message =~ "timeout_ms"
    end
  end

  describe "not configured" do
    test "every call returns :not_configured" do
      assert Observability.factory_overview(:day) == {:error, :not_configured}
      assert Observability.issue_metrics("TRUST-1") == {:error, :not_configured}
      assert Observability.issue_traces("TRUST-1") == {:error, :not_configured}
      assert Observability.trace(@trace_id) == {:error, :not_configured}
      assert Observability.issue_logs("TRUST-1") == {:error, :not_configured}
    end

    test "bad arguments are rejected before any request" do
      assert Observability.factory_overview(:year) == {:error, :invalid_range}
      assert Observability.factory_overview(-5) == {:error, :invalid_range}
      assert Observability.issue_metrics("  ") == {:error, :invalid_identifier}
      assert Observability.issue_metrics(String.duplicate("x", 300)) == {:error, :invalid_identifier}
      assert Observability.issue_traces(nil) == {:error, :invalid_identifier}
      assert Observability.trace("bad id; DROP") == {:error, :invalid_trace_id}
      assert Observability.trace(42) == {:error, :invalid_trace_id}
    end
  end

  describe "metrics from ClickHouse" do
    setup do
      configure!(@clickhouse, "pricing:\n  codex: {input_per_mtok: 2, output_per_mtok: 8, cached_input_per_mtok: 0.5}")
      stub!(clickhouse_responder())
      :ok
    end

    test "factory_overview combines totals, breakdowns, series, tools and latency" do
      assert {:ok, overview} = Observability.factory_overview(:day)

      assert overview.range == :day
      assert overview.bucket_seconds == 3_600
      assert DateTime.diff(overview.to, overview.from) == 86_400

      # Codex: 1M uncached * 2 + 1M cached * 0.5 + 1M out * 8 = 10.5 USD (estimated).
      totals = overview.totals
      assert totals.cost_usd == 12.0
      assert totals.estimated_cost_usd == 10.5
      assert %{tokens: 3_001_160, input_tokens: 1_000_100, output_tokens: 1_000_050} = totals
      assert %{cache_read_tokens: 1_001_000, cache_creation_tokens: 10} = totals
      assert %{tool_calls: 28, tool_errors: 2, turns: 3, api_requests: 40, api_errors: 1} = totals
      assert %{lines_added: 3, commits: 1} = totals
      # Request-weighted: (100 * 100 + 4898.5 * 60) / 160.
      assert_in_delta totals.api_p50_ms, 1899.4, 0.1
      assert_in_delta totals.api_p95_ms, 13_240.2, 0.15

      assert overview.by_backend["codex"].estimated_cost_usd == 10.5
      assert overview.by_backend["codex"].api_p50_ms == 100.0
      assert overview.by_backend["claude"].cost_usd == 1.5
      assert overview.by_backend["claude"].api_p95_ms == 33_790.4

      assert [codex_model, %{backend: "claude", model: "opus", api_requests: 0}] = overview.by_model
      assert %{backend: "codex", model: "gpt", cost_usd: 10.5, tokens: 3_000_000} = codex_model

      assert [%{identifier: "TRUST-2", title: nil, backends: ["codex"], cost_usd: 10.5}, %{identifier: "TRUST-1", tool_calls: 8}] =
               overview.top_issues

      assert overview.top_tools == [
               %{name: "exec_command", backend: "codex", calls: 20, errors: 2},
               %{name: "Bash", backend: "claude", calls: 8, errors: 0}
             ]

      assert overview.api_latency_ms["claude"] == %{p50: 4898.5, p95: 33_790.4, count: 60}
      assert overview.api_latency_ms["codex"] == %{p50: 100.0, p95: 910.0, count: 100}

      %{tokens: tokens, cost: cost, tool_calls: tool_calls} = overview.series
      assert length(tokens) in 24..25
      assert List.first(tokens).values == %{"claude" => 0, "codex" => 0}
      assert List.last(tokens).values == %{"claude" => 10, "codex" => 0}
      assert List.last(cost).values == %{"claude" => 0.25, "codex" => 0.0}
      assert List.last(tool_calls).values == %{"claude" => 0, "codex" => 4}
      assert Enum.map(tokens, & &1.at) == Enum.sort(Enum.map(tokens, & &1.at), DateTime)

      assert_received {:request, "ch.test", _path, body, params, ["Basic " <> auth]}
      assert Base.decode64!(auth) == "symphony:"
      assert body =~ "FORMAT JSON"
      assert params["database"] == "otel"
      # A readonly=1 user may not change settings, so none are sent.
      assert Map.keys(params) -- ["database", "param_from_ms", "param_bucket", "param_measures"] == []
    end

    test "issue_metrics filters by issue and instance and is cached" do
      assert {:ok, metrics} = Observability.issue_metrics("TRUST-1", :hour, instance: "AI Gym")
      assert metrics.identifier == "TRUST-1"
      assert metrics.bucket_seconds == 300
      refute Map.has_key?(metrics, :top_issues)

      assert_received {:request, "ch.test", _path, body, params, _auth}
      assert body =~ "{issue:String}"
      assert params["param_issue"] == "TRUST-1"
      assert params["param_instance"] == "AI Gym"
      assert params["param_instance_encoded"] == "AI%20Gym"

      flush_requests()
      assert {:ok, ^metrics} = Observability.issue_metrics("TRUST-1", :hour, instance: "AI Gym")
      refute_received {:request, _, _, _, _, _}
    end

    test "custom ranges in seconds pick a bucket" do
      assert {:ok, %{bucket_seconds: 120, range: 7_200}} = Observability.factory_overview(7_200)
      assert {:ok, %{bucket_seconds: 60}} = Observability.factory_overview(600)
    end

    test "issue_logs returns recent events" do
      assert {:ok, [failed, ok, api_error]} = Observability.issue_logs("TRUST-1", limit: 3, errors_only: true)

      assert %{event: "claude_code.tool_result", tool: "Bash", success: false, duration_ms: 40.0, error: "ShellError", trace_id: nil} =
               failed

      assert ok.success == true
      assert ok.trace_id == @trace_id
      assert ok.attributes["nested"] == ~s({"a":1})
      assert ok.attributes["n"] == "5"
      assert api_error.success == nil
      assert api_error.severity == nil
      assert api_error.at == nil

      assert_received {:request, "ch.test", _path, body, params, _auth}
      assert body =~ "LogAttributes['success'] = 'false'"
      assert params["param_limit"] == "3"
      assert params["param_events"] == "['claude_code.tool_result','claude_code.api_error','codex.tool_result']"
    end
  end

  describe "ClickHouse failures" do
    setup do
      configure!(@clickhouse)
      :ok
    end

    test "HTTP errors, bad bodies and unreachable servers come back as errors" do
      stub!(fn _host, _path, _body, _params -> {:status, 500, "Code: 497. DB::Exception: readonly\n"} end)
      assert Observability.factory_overview(:day) == {:error, {:clickhouse_http, 500, "Code: 497. DB::Exception: readonly"}}

      Cache.clear()
      stub!(fn _host, _path, _body, _params -> {:raw, "not json"} end)
      assert Observability.issue_logs("TRUST-1") == {:error, :invalid_clickhouse_response}

      Cache.clear()
      stub!(fn _host, _path, _body, _params -> {:json, %{"unexpected" => true}} end)
      assert Observability.issue_logs("TRUST-1") == {:error, :invalid_clickhouse_response}

      Cache.clear()
      stub!(fn _host, _path, _body, _params -> {:transport, :econnrefused} end)
      assert Observability.issue_logs("TRUST-1") == {:error, {:clickhouse_unreachable, :econnrefused}}
    end

    test "a failing or crashing sub-query fails the whole overview" do
      stub!(clickhouse_responder(%{quantiles: {:status, 502, "bad gateway"}}))
      assert {:error, {:clickhouse_http, 502, "bad gateway"}} = Observability.factory_overview(:week)

      Cache.clear()
      stub!(clickhouse_responder(%{tools: {:crash}}))

      capture_log(fn ->
        assert {:error, {:query_failed, _reason}} = Observability.factory_overview(:week)
      end)
    end
  end

  describe "traces" do
    test "issue_traces from ClickHouse link to the Langfuse project" do
      configure!(@clickhouse <> @langfuse)
      stub!(clickhouse_responder())

      assert {:ok, [trace]} = Observability.issue_traces("TRUST-758", limit: 5, min_spans: 2)

      assert trace == %{
               id: @trace_id,
               trace_id: @trace_id,
               name: "turn/start",
               started_at: DateTime.from_unix!(1_792_528_820_609, :millisecond),
               duration_ms: 836_872,
               span_count: 35_119,
               error_count: 1,
               error: true,
               backend: "codex",
               service: "codex-app-server",
               langfuse_url: "https://langfuse.example.com/project/proj-1/traces/#{@trace_id}"
             }

      assert_received {:request, "ch.test", _path, _body, %{"param_min_spans" => "2", "param_limit" => "5"}, _auth}

      assert {:ok, [%{id: @trace_id}]} = Observability.issue_traces("TRUST-758", 3)
      assert_received {:request, "ch.test", _path, _body, %{"param_limit" => "3"}, _auth}
    end

    test "status probes each configured source and is cached" do
      assert Observability.status() == %{
               clickhouse: %{state: :not_configured, error: nil},
               langfuse: %{state: :not_configured, error: nil}
             }

      Cache.clear()
      configure!(@clickhouse <> @langfuse)

      stub!(fn
        "ch.test", _path, "SELECT 1 AS ok\nFORMAT JSON", _params -> data([%{"ok" => 1}])
        "lf.test", _path, _body, _params -> {:status, 401, ""}
      end)

      assert Observability.status() == %{
               clickhouse: %{state: :ok, error: nil},
               langfuse: %{state: :error, error: {:langfuse_http, 401}}
             }

      flush_requests()
      assert %{clickhouse: %{state: :ok}} = Observability.status()
      refute_received {:request, _, _, _, _, _}
    end

    test "issue_traces without public_url or a project have plain or no links" do
      configure!(@clickhouse)
      stub!(clickhouse_responder())
      assert {:ok, [%{langfuse_url: nil}]} = Observability.issue_traces("TRUST-758")

      Cache.clear()

      configure!(@clickhouse <> @langfuse)

      stub!(fn
        "lf.test", "/api/public/projects", _body, _params -> {:json, %{"data" => []}}
        host, path, body, params -> clickhouse_responder().(host, path, body, params)
      end)

      assert {:ok, [%{langfuse_url: "https://langfuse.example.com/trace/" <> @trace_id}]} = Observability.issue_traces("TRUST-758")
    end

    test "issue_traces fall back to Langfuse metadata when ClickHouse is not configured" do
      configure!(@langfuse)

      traces = [
        %{
          "id" => "t1",
          "name" => "claude_code.interaction",
          "timestamp" => "2026-10-20T10:00:00.000Z",
          "latency" => 1.5,
          "observations" => ["o1", "o2"],
          "htmlPath" => "/project/p/traces/t1",
          "metadata" => %{
            "count" => 3,
            "resourceAttributes" => %{"linear.issue.identifier" => "TRUST-9", "symphony.backend" => "claude"}
          }
        },
        %{"id" => "t2", "metadata" => %{"attributes" => %{"linear.issue.identifier" => "TRUST-10"}}},
        %{"id" => "t3", "metadata" => "plain"}
      ]

      stub!(fn "lf.test", "/api/public/traces", _body, params ->
        send(self(), {:params, params})
        {:json, %{"data" => traces, "meta" => %{"page" => 1}}}
      end)

      assert {:ok, [trace]} = Observability.issue_traces("TRUST-9")

      assert %{
               trace_id: "t1",
               duration_ms: 1500.0,
               span_count: 2,
               backend: "claude",
               langfuse_url: "https://langfuse.example.com/project/p/traces/t1"
             } = trace

      assert_received {:request, "lf.test", "/api/public/traces", _body, params, ["Basic " <> auth]}
      assert Base.decode64!(auth) == "pk-test:sk-test"
      assert params["orderBy"] == "timestamp.desc"
      assert params["fromTimestamp"] =~ "T"

      Cache.clear()
      stub!(fn _host, _path, _body, _params -> {:json, %{"data" => "nope"}} end)
      assert Observability.issue_traces("TRUST-9") == {:error, :invalid_langfuse_response}
    end

    test "trace prefers Langfuse observations for small traces" do
      configure!(@clickhouse <> @langfuse)

      langfuse_trace = %{
        "id" => @trace_id,
        "name" => "claude_code.interaction",
        "timestamp" => "2026-10-20T10:00:00.000Z",
        "latency" => 2.0,
        "totalCost" => 0.05,
        "htmlPath" => "/project/p/traces/#{@trace_id}",
        "observations" => [
          %{
            "id" => "g1",
            "parentObservationId" => "s1",
            "type" => "GENERATION",
            "name" => "llm",
            "startTime" => "2026-10-20T10:00:00.500Z",
            "endTime" => "2026-10-20T10:00:01.500Z",
            "level" => "ERROR",
            "statusMessage" => "overloaded",
            "model" => "opus",
            "usage" => %{"input" => 10, "output" => 5, "total" => 15, "unit" => "TOKENS"},
            "usageDetails" => %{"input" => 10, "output" => 5, "cache_read_input_tokens" => "100", "weird" => 1},
            "calculatedTotalCost" => 0.04,
            "metadata" => %{"attributes" => %{"gen_ai.system" => "anthropic"}, "resourceAttributes" => %{"service.name" => "claude-code"}}
          },
          %{
            "id" => "s1",
            "type" => "SPAN",
            "name" => "interaction",
            "startTime" => "2026-10-20T10:00:00.000Z",
            "endTime" => "2026-10-20T10:00:02.000Z",
            "level" => "DEFAULT",
            "costDetails" => %{"total" => 0.01},
            "metadata" => %{"k" => "v"}
          },
          %{"id" => "e1", "type" => "EVENT", "startTime" => "garbage", "level" => "WARNING", "latency" => 0.25, "totalCost" => "0.002"},
          "not a map"
        ]
      }

      stub!(clickhouse_responder(%{{:langfuse, "/api/public/traces/#{@trace_id}"} => {:json, langfuse_trace}}))

      assert {:ok, trace} = Observability.trace(@trace_id)
      assert %{source: :langfuse, span_count: 3, shown_spans: 3, truncated: false, error: true, cost_usd: 0.05} = trace
      assert trace.duration_ms == 2000.0
      assert trace.started_at == ~U[2026-10-20 10:00:00.000Z]
      assert trace.langfuse_url == "https://langfuse.example.com/project/p/traces/#{@trace_id}"
      assert trace.url == trace.langfuse_url
      assert trace.id == @trace_id

      assert [%{id: "e1"} = event, %{id: "s1"} = root, %{id: "g1"} = generation] = trace.spans
      assert event.otel_status == :warning and event.status == "ok"
      assert event.duration_ms == 250.0
      assert event.cost_usd == 0.002
      assert root.parent_id == nil
      assert root.cost_usd == 0.01
      assert root.otel_status == :unset
      assert root.attributes == %{"k" => "v"}
      assert generation.parent_id == "s1"
      assert generation.type == "generation"
      assert generation.status == "error"
      assert generation.start_offset_ms == 500.0
      assert generation.duration_ms == 1000.0
      assert generation.usage == %{input: 10, output: 5, total: 15, cache_read: 100.0}
      assert generation.cost_usd == 0.04
      assert generation.service == "claude-code"
      assert generation.attributes == %{"gen_ai.system" => "anthropic"}
    end

    test "Langfuse traces are trimmed to max_spans" do
      configure!(@langfuse)

      observations =
        for i <- 1..5 do
          %{
            "id" => "o#{i}",
            "parentObservationId" => if(i == 1, do: nil, else: "o1"),
            "startTime" => "2026-10-20T10:00:0#{i}.000Z",
            "endTime" => "2026-10-20T10:00:0#{i}.#{i}00Z"
          }
        end

      stub!(fn "lf.test", "/api/public/traces/abc", _body, _params ->
        {:json, %{"id" => "abc", "observations" => observations, "metadata" => nil}}
      end)

      assert {:ok, trace} = Observability.trace("abc", max_spans: 2)
      assert %{source: :langfuse, span_count: 5, shown_spans: 2, truncated: true, name: nil, cost_usd: nil} = trace
      assert trace.langfuse_url == "https://langfuse.example.com/trace/abc"
      assert Enum.map(trace.spans, & &1.id) == ["o1", "o5"]
      assert trace.duration_ms == 4500.0

      stub!(fn "lf.test", "/api/public/traces/empty", _body, _params -> {:json, %{"id" => "empty"}} end)
      assert {:ok, %{spans: [], duration_ms: 0, started_at: nil, span_count: 0}} = Observability.trace("empty")
    end

    test "trace falls back to ClickHouse spans when Langfuse misses or the trace is big" do
      configure!(@clickhouse <> @langfuse)
      stub!(clickhouse_responder())

      assert {:ok, trace} = Observability.trace(@trace_id)
      assert %{source: :clickhouse, span_count: 3, shown_spans: 3, truncated: false, error: true} = trace
      assert trace.duration_ms == 500
      assert trace.name == "claude_code.interaction"
      assert trace.started_at == DateTime.from_unix!(1000, :millisecond)
      assert trace.langfuse_url == "https://langfuse.example.com/project/proj-1/traces/#{@trace_id}"

      assert [root, llm, exec] = trace.spans
      assert %{id: "a", parent_id: nil, status: "ok", otel_status: :ok, start_ms: +0.0, duration_ms: 500.0} = root
      assert %{type: "server", start_offset_ms: +0.0} = root
      assert String.length(root.attributes["long"]) == 500

      assert %{parent_id: "a", status: "error", status_message: "boom", model: "opus", cost_usd: 0.01} = llm
      assert llm.start_offset_ms == 100.0
      assert llm.detail == "boom · opus · 12 in / 3 out · $0.0100"

      assert llm.usage == %{input: 12.0, output: 3.0}
      assert %{parent_id: nil, type: nil, otel_status: :unset, detail: nil, usage: nil, attributes: %{}} = exec

      assert_received {:request, "ch.test", _path, _summary_body, %{"param_trace_id" => @trace_id}, _auth}

      # Bigger than max_spans: Langfuse is not asked.
      Cache.clear()
      flush_requests()
      assert {:ok, %{source: :clickhouse, span_count: 3}} = Observability.trace(@trace_id, max_spans: 2, min_duration_ms: 5)
      refute_received {:request, "lf.test", "/api/public/traces/" <> _, _, _, _}
    end

    test "trace reports not found and Langfuse errors" do
      configure!(@clickhouse)
      stub!(clickhouse_responder(%{summary: data([%{"span_count" => "0"}])}))
      assert Observability.trace(@trace_id) == {:error, :not_found}

      Cache.clear()
      stub!(clickhouse_responder(%{summary: data([])}))
      assert Observability.trace(@trace_id) == {:error, :not_found}

      Cache.clear()
      stub!(clickhouse_responder(%{spans: {:status, 500, "x"}}))
      assert Observability.trace(@trace_id) == {:error, {:clickhouse_http, 500, "x"}}

      Cache.clear()
      stub!(clickhouse_responder(%{summary: {:status, 500, "y"}}))
      assert Observability.trace(@trace_id) == {:error, {:clickhouse_http, 500, "y"}}

      Cache.clear()
      configure!(@langfuse)
      stub!(fn _host, _path, _body, _params -> {:status, 401, "unauthorized"} end)
      assert Observability.trace(@trace_id) == {:error, {:langfuse_http, 401}}

      Cache.clear()
      stub!(fn _host, _path, _body, _params -> {:json, %{"no" => "id"}} end)
      assert Observability.trace(@trace_id) == {:error, :invalid_langfuse_response}

      Cache.clear()
      stub!(fn _host, _path, _body, _params -> {:transport, :timeout} end)
      assert Observability.trace(@trace_id) == {:error, {:langfuse_unreachable, :timeout}}
    end
  end

  describe "Langfuse client" do
    @config %{url: "http://lf.test:3000/", public_key: "pk", secret_key: "sk"}

    test "project ids, links and tolerant bodies" do
      stub!(fn _host, _path, _body, _params -> {:raw, ~s({"data":[{"id":"p9"}]})} end)
      assert Langfuse.project_id(@config) == {:ok, "p9"}

      stub!(fn _host, _path, _body, _params -> {:raw, "[1]"} end)
      assert Langfuse.project_id(@config) == {:error, :invalid_langfuse_response}

      stub!(fn _host, _path, _body, _params -> {:json, %{"data" => "x"}} end)
      assert Langfuse.project_id(@config) == {:error, :invalid_langfuse_response}

      stub!(fn _host, _path, _body, _params -> {:status, 503, ""} end)
      assert Langfuse.project_id(@config) == {:error, {:langfuse_http, 503}}
      assert Langfuse.traces(@config, []) == {:error, {:langfuse_http, 503}}

      stub!(fn _host, _path, _body, _params -> {:json, [1, 2]} end)
      assert Langfuse.trace(@config, "t") == {:error, :invalid_langfuse_response}

      stub!(fn _host, _path, _body, _params -> {:json, %{"id" => "empty"}} end)
      assert {:ok, %{"id" => "empty"}} = Langfuse.trace(@config, "empty")

      assert Langfuse.trace_url(@config, "t", "p") == nil
      assert Langfuse.trace_url(Map.put(@config, :public_url, ""), "t", "p") == nil
      assert Langfuse.trace_url(Map.put(@config, :public_url, "https://lf/"), "a b", "p") == "https://lf/project/p/traces/a+b"
      assert Langfuse.html_url(@config, "/project/p") == nil
      assert Langfuse.html_url(Map.put(@config, :public_url, "https://lf"), nil) == nil
    end
  end

  describe "ClickHouse client" do
    test "parameters are escaped and numbers parsed" do
      assert ClickHouse.encode_param(["a'b", "c\\d", 1]) == "['a\\'b','c\\\\d','1']"
      assert ClickHouse.encode_param("x\\y") == "x\\\\y"
      assert ClickHouse.encode_param(42) == "42"

      assert ClickHouse.number("12") == 12
      assert ClickHouse.number("12.5") == 12.5
      assert ClickHouse.number("1e3") == 1000.0
      assert ClickHouse.number("nope") == 0
      assert ClickHouse.number(nil) == 0
      assert ClickHouse.number_or_nil("3") == 3.0
      assert ClickHouse.number_or_nil("x") == nil
      assert ClickHouse.number_or_nil(nil) == nil
    end

    test "a missing user sends no auth, and a missing timeout uses the default" do
      stub!(fn _host, _path, _body, _params -> data([%{"x" => 1}]) end)
      assert ClickHouse.query(%{url: "http://ch.test:8123"}, "SELECT 1 AS x") == {:ok, [%{"x" => 1}]}
      assert_received {:request, "ch.test", _path, "SELECT 1 AS x\nFORMAT JSON", %{"database" => "otel"}, []}

      stub!(fn _host, _path, _body, _params -> {:status, 400, ""} end)
      assert ClickHouse.query(%{url: "http://ch.test:8123", user: "u"}, "SELECT 1") == {:error, {:clickhouse_http, 400, ""}}
    end

    test "latency rows tolerate missing quantiles" do
      stub!(fn _host, _path, body, _params ->
        if body =~ "'histogram'", do: data([]), else: data([%{"backend" => "claude", "kind" => "quantiles", "q" => nil, "count" => "0"}])
      end)

      assert ClickHouse.latency(%{url: "http://ch.test:8123"}, %{}, from_ms: 0) ==
               {:ok, [%{"backend" => "claude", "kind" => "quantiles", "p50" => nil, "p95" => nil, "count" => 0}]}
    end
  end

  describe "metrics helpers" do
    test "histogram quantiles interpolate inside buckets" do
      assert Metrics.histogram_quantile([0, 10, 100], [0, 0, 0, 0], 0.5) == nil
      assert Metrics.histogram_quantile([0, 10, 100], [0, 10, 10, 0], 0.5) == 10.0
      assert Metrics.histogram_quantile([0, 10, 100], [0, 10, 10, 0], 0.75) == 55.0
      # Overflow bucket reports the last bound.
      assert Metrics.histogram_quantile([0, 10], [0, 0, 5], 0.9) == 10.0
      assert Metrics.histogram_quantile([], [3], 0.5) == 0.0
    end

    test "unpriced groups get no estimate and unknown rows are ignored" do
      rows = [%{"backend" => "opencode", "model" => "", "measure" => "tokens_input", "value" => "5"}]
      assert Metrics.prepare(rows, %{}) == [%{"backend" => "opencode", "model" => "", "measure" => "tokens_input", "value" => 5}]
      assert Metrics.totals([%{"other" => 1}]) == Metrics.empty_totals()
      assert Metrics.latency([]) == %{}
      assert Metrics.overall_latency(%{}) == %{p50: nil, p95: nil}

      assert Metrics.latency([%{"backend" => "claude", "kind" => "quantiles", "p50" => nil, "p95" => nil, "count" => 0}]) ==
               %{"claude" => %{p50: nil, p95: nil, count: 0}}
    end
  end

  describe "cache" do
    test "values are kept for the TTL and errors only briefly" do
      parent = self()
      fun = fn -> send(parent, :computed) && {:ok, 1} end

      assert Cache.fetch(:k, 60_000, fun) == {:ok, 1}
      assert Cache.fetch(:k, 60_000, fun) == {:ok, 1}
      assert_received :computed
      refute_received :computed

      assert Cache.fetch(:short, 1, fun) == {:ok, 1}
      Process.sleep(5)
      assert Cache.fetch(:short, 1, fun) == {:ok, 1}
      assert_received :computed
      assert_received :computed

      assert Cache.fetch(:zero, 0, fun) == {:ok, 1}
      assert Cache.fetch(:zero, 0, fun) == {:ok, 1}
      assert_received :computed
      assert_received :computed

      failing = fn -> send(parent, :failed) && {:error, :down} end
      assert Cache.fetch(:err, 60_000, failing) == {:error, :down}
      assert Cache.fetch(:err, 60_000, failing) == {:error, :down}
      assert_received :failed
      refute_received :failed

      [{:err, _value, expires_at}] = :ets.lookup(:symphony_observability_cache, :err)
      assert expires_at - System.monotonic_time(:millisecond) <= 5_000
    end

    test "without its table the cache computes every time" do
      pid = Process.whereis(Cache)
      Supervisor.terminate_child(SymphonyElixir.Supervisor, Cache)
      on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, Cache) end)
      refute Process.alive?(pid)

      parent = self()
      assert Cache.fetch(:k, 60_000, fn -> send(parent, :computed) && :v end) == :v
      assert Cache.fetch(:k, 60_000, fn -> send(parent, :computed) && :v end) == :v
      assert_received :computed
      assert_received :computed
      assert Cache.clear() == :ok

      {:ok, pid} = Cache.start_link(name: :observability_cache_test)
      # A second owner leaves the existing table alone.
      {:ok, other} = GenServer.start(Cache, [])
      GenServer.stop(other)
      GenServer.stop(pid)
    end
  end

  defp flush_requests do
    receive do
      {:request, _, _, _, _, _} -> flush_requests()
    after
      0 -> :ok
    end
  end
end
