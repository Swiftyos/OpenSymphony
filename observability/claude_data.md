# Observability Data Reference

Findings from probing the live VictoriaMetrics, VictoriaLogs, and Grafana stack while building `claude-code-issues.json`. This is what actually exists in the data as of 2026-04-23, not what docs say should exist.

## Stack endpoints

| Service | Host port | Internal | Notes |
|---|---|---|---|
| VictoriaMetrics | `localhost:11341` | `http://victoriametrics:8428` | Prometheus-compatible `/api/v1/*` |
| VictoriaLogs | `localhost:11342` | `http://victorialogs:9428` | LogsQL via `/select/logsql/query` |
| VictoriaTraces | `localhost:11343` | `http://victoriatraces:10428` | OTLP in, Jaeger out at `/select/jaeger` |
| Vector OTLP gRPC | `localhost:11338` | `http://vector:4317` | For metrics only (logs/traces bypass vector) |
| Vector OTLP HTTP | `localhost:11339` | `http://vector:4318` | Unused — symphony points signals at Victoria* directly |
| Grafana | `localhost:11337` | — | admin/admin |

Direct OTLP endpoints used by symphony (set as per-signal `OTEL_EXPORTER_OTLP_*_ENDPOINT`):

- Traces: `http://localhost:11343/insert/opentelemetry/v1/traces` (`http/protobuf`)
- Logs: `http://localhost:11342/insert/opentelemetry/v1/logs` (`http/protobuf`)
- Metrics: `http://localhost:11338` (`grpc`, via Vector)

## Grafana datasource UIDs

| Name | Type | UID |
|---|---|---|
| VictoriaMetrics | `victoriametrics-metrics-datasource` | `victoriametrics` |
| VictoriaLogs | `victoriametrics-logs-datasource` | `victorialogs` |
| Jaeger (traces) | `jaeger` | `jaeger` |

## Metrics available (VictoriaMetrics)

Enumerated with `group by (__name__) ({__name__=~"claude_code.*"}[7d])`:

| Metric | Kind | Useful for |
|---|---|---|
| `claude_code.token.usage` | counter | Tokens by issue/type/model/backend |
| `claude_code.cost.usage` | counter | USD cost per issue |
| `claude_code.session.count` | counter | Session starts |
| `claude_code.commit.count` | counter | Commits created |
| `claude_code.pull_request.count` | counter | PRs opened |
| `claude_code.lines_of_code.count` | counter | LoC added/removed |
| `claude_code.code_edit_tool.decision` | counter | Edit-tool accept/reject |

**Does NOT exist** (tried during dashboard build): `claude_code.api.error`, `claude_code.api_error`, `claude_code.error`, `claude_code.tool_use`, `claude_code.api.request`, `claude_code.api_request`. For error rates use LogsQL on `event.name:in(api_error, internal_error)` instead.

## Metric label shape

OTLP resource attributes arrive **with the `resource.` prefix preserved** in VictoriaMetrics:

- `resource.linear.issue.identifier` (e.g. `ANA-213`)
- `resource.linear.issue.id` (UUID)
- `resource.symphony.backend` (e.g. `claude`)
- `resource.symphony.instance` (e.g. `Anathem`)
- `resource.service.name`, `resource.service.version`
- `resource.host.arch`, `resource.os.type`, etc.

Non-resource labels on `claude_code.token.usage`:

- `type` — one of `input`, `output`, `cacheRead`, `cacheCreation` (**camelCase**, not `cache_read`/`cache_creation`)
- `model` — e.g. `claude-sonnet-4-6`

Some series have an empty `{}` label set (metrics emitted before the parent process attached resource labels). Filter with `"resource.linear.issue.identifier"=~".+"` to exclude these when aggregating by issue.

## Current metric totals (last 7d)

| Issue | Cost | cacheCreation | cacheRead | input | output |
|---|---|---|---|---|---|
| ANA-211 | $1.64 | 90 948 | 3 041 689 | 82 | 25 224 |
| ANA-213 | $13.68 | 355 846 | 20 230 670 | 468 | 85 533 |
| ANA-216 | $2.43 | 104 068 | 2 577 326 | 93 | 19 380 |

Only one backend seen: `claude`.

## Logs available (VictoriaLogs)

Event types seen in last 7d via `* | stats by (event.name) count() as n | sort by (n desc)`:

| `event.name` | Count | Key fields |
|---|---|---|
| `tool_result` | 195 | `tool_name`, `tool_input` (JSON), `tool_parameters` (JSON, only for some), `duration_ms`, `success`, `tool_result_size_bytes` |
| `api_request` | 194 | `input_tokens`, `output_tokens`, `cache_creation_tokens`, `cache_read_tokens`, `cost_usd`, `model`, `duration_ms`, `request_id` |
| `tool_decision` | 191 | tool accept/reject decisions |
| `internal_error` | 29 | harness-side errors |
| `api_error` | 16 | provider-side errors |
| `user_prompt` | 15 | only has content when `OTEL_LOG_USER_PROMPTS=1` |
| `mcp_server_connection` | 7 | MCP attach events |
| `skill_activated` | 4 | `skill.name`, `skill.source` |

### Common fields on every event

- `_time`, `_stream`, `_stream_id`, `_msg` (= `claude_code.<event.name>`)
- `event.name`, `event.sequence`, `event.timestamp`
- `linear.issue.id`, `linear.issue.identifier`
- `session.id`, `prompt.id`
- `symphony.backend`, `symphony.instance`
- `user.account_id`, `user.email`, `user.id`
- `service.name`, `service.version`, `scope.name`, `scope.version`
- `host.arch`, `os.type`, `os.version`, `terminal.type`
- `environment` (from `resource_attributes.environment: symphony`)

Note: in VictoriaLogs these arrive **without** the `resource.` prefix that VictoriaMetrics preserves. `linear.issue.identifier` in logs ≡ `resource.linear.issue.identifier` in metrics.

### `tool_name` values seen

| Tool | Count |
|---|---|
| Bash | 113 |
| ToolSearch | 46 |
| Read | 16 |
| TodoWrite | 9 |
| Skill | 4 |
| Edit | 4 |
| Agent | 2 |
| Write | 1 |

**Not seen yet**: `Grep`, `WebSearch`, `NotebookEdit`, `Glob`. Queries still include them so the dashboard starts populating those columns as soon as they're used.

### `tool_input` JSON shape (after `| unpack_json from tool_input`)

Tool input is stored as a single JSON-string field `tool_input`. Use `| unpack_json from tool_input` to promote its keys to top-level fields. Observed schemas:

| Tool | Keys after unpack | Aggregate by |
|---|---|---|
| `Read` | `file_path` | `file_path` |
| `Bash` | `command`, `description` | `command` |
| `Skill` | `skill`, `args` | `skill` |
| `TodoWrite` | `todos` (array, nested placeholders `<nested>`) | not useful to aggregate |
| `ToolSearch` | `query` | `query` |
| `WebSearch` (expected) | `query` | `query` |
| `Edit`/`Write` (expected) | `file_path`, `old_string`/`new_string` | `file_path` |

For a universal "top exact calls" aggregate across tools:

```
event.name:tool_result | unpack_json from tool_input
  | stats by (tool_name, file_path, command, query, pattern) count() as n
  | sort by (n desc) | limit 30
```

Tools whose input doesn't include a given field simply show empty there.

### `tool_input` is NULL for sessions where `OTEL_LOG_TOOL_DETAILS` wasn't set

Sessions before 2026-04-22 and any session spawned without the env var have `tool_input: None`. Those events still contribute to tool-count panels but contribute an empty-input row to exact-match panels. This is a data issue, not a query issue — resolved automatically for new sessions now that the config carries `log_tool_details: true`.

### `skill_activated` fields

- `skill.name` — real values: `linear`, `review`, `security-review`, etc. when `OTEL_LOG_TOOL_DETAILS=1`. Falls back to the literal string `custom_skill` when tool details aren't enabled (this is Claude Code's redaction, not a bug).
- `skill.source` — e.g. `projectSettings`, `userSettings`, `plugin`.

Currently no `review` or `security-review` activations exist in the data. That's the correct answer to "do all issues have review/security-review invoked?" → **no, none do yet**.

## Query syntax quirks

### LogsQL (VictoriaLogs)

Works:

- `| unpack_json from tool_input` — promotes JSON keys to fields
- `| fields _time, tool_name, ...` — keeps only named fields; hides the noisy `_msg` and label blob in `logs`/`table` panels
- `| stats by (_time:5m, label) count() as n` — time-bucketed aggregate; valid bucket units: `1s`, `5m`, `1h`, `1d`
- `| stats by (x) count_uniq(y) as distinct_y` — distinct count of `y` grouped by `x`
- `| stats by (x) min(_time) as first, max(_time) as last` — first/last timestamps
- `tool_name:in(Read, Edit, Write)` — multi-value OR
- `skill.name:"security-review"` — hyphenated values need quotes
- `| sort by (field asc)` / `| sort by (field desc)` / `| sort by (a, b)`
- `| limit N`

Does **not** work:

- `uniq(field)` — use `count_uniq(field)` instead
- `values(field)` as an aggregate — not supported
- Sequence / N-gram detection (no `next_event`, no window over ordered events)

### PromQL / MetricsQL (VictoriaMetrics)

Works:

- `{__name__="claude_code.token.usage"}` — selector with dot in metric name
- `sum by ("resource.linear.issue.identifier") (...)` — **dotted labels must be quoted**
- `"resource.linear.issue.identifier"=~".+"` — quoted regex selector to exclude empty-label series
- `increase(counter[$__range])` with `instant: true` in Grafana target — yields one value per series, correct for "total in selected range"
- `rate(counter[5m])` — standard throughput
- `group by (__name__) ({__name__=~"prefix.*"}[7d])` — enumerate metric names in a time window

Does **not** work:

- `count({...})` on a bare counter without a range vector returns zero series
- `/api/v1/label/__name__/values` endpoint returns empty on this VictoriaMetrics build — use `group by (__name__) ({__name__=~".+"}[Nd])` instead

## Grafana panel recipes

### Counter totals → categorical bar chart (per-issue)

```
sum by ("resource.linear.issue.identifier", type) (
  increase({__name__="claude_code.token.usage", "resource.linear.issue.identifier"=~".+"}[$__range])
)
```

- Target: `instant: true`, `legendFormat: "{{type}}"`
- Transform: `labelsToFields` with `valueLabel: "type"` then `organize` to order columns
- Panel type: `barchart` with `xField: "resource.linear.issue.identifier"` and `stacking.group: "A"`

### Merged multi-query table (per-issue Discovery vs Write)

Three `stats by (linear.issue.identifier) count() as <name>` queries with different tool filters. Transform chain: `merge` → `organize` (`indexByName`).

### Skill coverage matrix with red-for-missing cells

Master query: `event.name:api_request | stats by (linear.issue.identifier) count() as api_calls` (ensures every active issue appears as a row).

Three child queries for `skill_activated skill.name:<skill>` each producing a `<skill>` count column.

Transform: `merge` then `organize` with `excludeByName: { api_calls: true }`. Field override on the skill columns: `custom.cellOptions.type = color-background-solid`, `thresholds` = red below 1 / green at 1+, `noValue: "0"` so missing rows render as zeroed red cells.

### Clean sequential tool-call table

```
event.name:tool_result | unpack_json from tool_input
  | fields _time, linear.issue.identifier, session.id, tool_name, file_path, command, query
  | sort by (session.id, _time asc) | limit 500
```

Panel type: `table` (not `logs` — logs panels dump `_msg` + labels blob and are unreadable). Set `custom.wrap: true` on free-text columns; `custom.wrap: false` on `_time`, `session.id`, `tool_name`.

## Harness invariants that load-bear on these queries

- **`OTEL_LOG_TOOL_DETAILS=1`** → `tool_input`, `tool_parameters`, and real `skill.name` values (without this, `skill.name` is literally `custom_skill`).
- **`OTEL_LOG_USER_PROMPTS=1`** → `user_prompt` events include content.
- **Resource attribute injection in `SymphonyElixir.Telemetry.env_pairs/2`** → `resource.linear.issue.identifier` and `resource.symphony.backend` on metrics; `linear.issue.identifier` and `symphony.backend` (no prefix) on logs.
- **Separate OTLP endpoints per signal** → traces and logs bypass Vector (direct Victoria*); only metrics go via Vector's `prometheus_remote_write` sink.

If any of these regress, the dashboard degrades in predictable ways: skill.name goes back to `custom_skill`, tool_input becomes null, or signals stop arriving entirely (Vector can't re-serialize OTLP in its sink).
