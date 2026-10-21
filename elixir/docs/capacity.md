# Capacity metrics

Symphony exposes per-agent capacity measurements on the same Prometheus endpoint as the account
metrics (`GET /metrics`). They answer the sizing questions we need before moving from a handful of
agents on one VM to many agents on Kubernetes.

The sampler runs in the application tree and is configured in `symphony.yml` or the legacy
`WORKFLOW.md` front matter:

```yaml
capacity:
  sample_interval_ms: 30000  # default; 0 disables the sampler
```

`sample_interval_ms` must be `0` (off) or at least `1000`; smaller positive values are rejected
instead of scheduling a tight loop.

The Linear and git counters are always recorded; `sample_interval_ms: 0` only disables the periodic
CPU/memory sampler.

## Metrics

### Linear API

- `symphony_linear_requests_total{operation,outcome}`: requests Symphony made to Linear. `operation`
  is the GraphQL operation parsed from the query text (for example `SymphonyCreateComment`), and
  `outcome` is `ok`, `error`, or `rate_limited`.
- `symphony_linear_request_duration_seconds{operation}`: histogram of request duration.
- `symphony_linear_rate_limit_remaining{kind}`: latest `x-ratelimit-requests-remaining` (`kind="requests"`)
  and `x-ratelimit-complexity-remaining` (`kind="complexity"`) values when Linear sends them.

### Git and GitHub setup

- `symphony_git_operations_total{operation,outcome}`: git/gh work Symphony ran while preparing a
  workspace. `operation` is `cache_clone_or_fetch` (the shared repo cache clone/fetch) or
  `workspace_create` (the per-issue clone). Agents' own git commands are not included.
- `symphony_git_operation_duration_seconds{operation}`: histogram of that setup work.

### Running agents

- `symphony_run_cpu_percent{issue,backend,stage}`: latest sampled CPU use, in percent of one CPU
  (100 means one full core). It is computed from the growth in cumulative CPU time between two
  samples, not from `ps %cpu` or one-shot `podman stats` percentages (both are lifetime averages).
- `symphony_run_memory_bytes{issue,backend,stage}`: latest sampled RSS/container memory, in bytes.
- `symphony_runs_sampled`: number of running agents matched by the latest sample, or `0` when the
  latest sample failed.
- `symphony_capacity_sample_errors_total{reason}`: failed samples by reason (`timeout`,
  `ps_failed`, `ps_parse_error`, `container_stats_failed`, `container_stats_parse_error`,
  `snapshot_*`, `command_exception`, `sampler_exception`).
- `symphony_run_cpu_percent_distribution`: histogram of every sample since start (0–800%).
- `symphony_run_memory_bytes_distribution`: histogram of every sample since start (0–32 GiB).
- `symphony_run_tokens_per_minute{issue,backend}`: token total for the run divided by the run's age.

### Runs hosted by a runner (Kubernetes pods, process runners)

The controller cannot see a runner pod's processes, so a runner measures itself
(`SymphonyElixir.Capacity.SelfUsage`) every `capacity.sample_interval_ms` and sends a `metrics`
event over `/runner/v1`. It tries three sources in order:

1. Its cgroup v2: `cpu.stat` `usage_usec`, and `memory.current` minus `memory.stat` `inactive_file`.
   That is the working set, as the kubelet and `kubectl top` count it.
2. Its cgroup v1: `cpuacct.usage`, and `memory.usage_in_bytes` minus `total_inactive_file`.
3. Its own process tree in `/proc`: CPU including reaped children, and resident memory.

A cgroup is used only when it belongs to the run alone: `/` in a namespaced container, or a
`symphony-run-*` systemd unit. A cgroup shared with anything else is skipped, and the process tree
is used instead. In a docker sandbox the runner does not report, because the controller's `stats`
call already sees the agent's container.

Under gVisor (GKE Sandbox), the sandbox kernel decides which of these files it emulates.
`symphony_run_usage_reports_total{source}` (`cgroup_v2`, `cgroup_v1`, `proc`) shows which source
answered. Check it on the first GKE runs: `proc` means the cgroup files were not readable in the
sandbox.

The sampler uses a report younger than three sample intervals as that run's sample. It writes the
same `symphony_run_cpu_percent`, `symphony_run_memory_bytes` and distribution series, with the same
`issue`, `backend` and `stage` labels. A runner-hosted run is never matched against the
controller's `ps`, because the agent pid it reports is its pod's.

With `sandbox.kind: docker`, one `docker`/`podman stats` call per sample covers all Symphony
containers and containers are mapped back to issues by workspace. Without a sandbox, one
portable `ps -e -o pid=,ppid=,rss=,time=` call per sample covers the process trees of the local
agent app servers, including child processes.

The first sample of a run records memory only; CPU appears from the second sample once a delta is
available. For processes the delta uses the summed cumulative `ps` CPU time of the tree. For
containers it uses a cumulative CPU-time field when the stats output has one (`CPUNano`,
`cpu_time_ns`, ...); when it does not, the sampler falls back to the reported one-shot percentage,
which is an average since container start and therefore only indicative for long-lived containers.

Every command runs with a `10s` deadline: on timeout the sampler kills the child process, records
`symphony_capacity_sample_errors_total{reason="timeout"}`, sets `symphony_runs_sampled` to `0`, and
leaves the previous per-run gauges in place. Gauges for runs that have finished are deleted only
after a successful sample. Sampler failures (missing container command, unreadable `ps`, invalid
JSON) are logged once per kind of error and never crash Symphony; a successful sample clears that
record so a later failure is logged again.

### Agents

These are recorded where in-process and runner-hosted runs converge, so a pod's run counts exactly
like a local one. Runner events are deduplicated by seq before they are counted.

- `symphony_agent_tokens_total{backend,type}`: tokens by `type` (`input`, which includes cached
  input, `output`, `cached_input`). The deltas are the ones the usage ledger records.
- `symphony_agent_turns_total{backend}`: turns started.
- `symphony_agent_tool_calls_total{backend,outcome}`: tool calls that finished. This covers
  commands, edits, MCP and dynamic tools, Claude Code tool results and OpenCode tool parts.
  `outcome` is `ok` or `error` (failed or declined). A call is counted from its final transcript
  status, and an entry without a status (Codex web searches) is not counted.
- `symphony_agent_runs_total{backend,outcome}` and the histogram
  `symphony_agent_run_duration_seconds{backend,outcome}` (30s to 12h): runs that left `running`.
  The outcomes are `finished`, `crashed`, `stalled`, `closed`, `paused`, `moved` and `missing`.
  A run that ended while the controller was down is not counted.

### Kubernetes runner pods

These come from the controller's single pod watch (`agent.launcher: kubernetes`; see
[durable-runs.md](durable-runs.md)):

- `symphony_runner_pods{phase}`: runner pods by phase (`pending`, `running`, `succeeded`,
  `failed`, `unknown`). Finished pods stay until the janitor deletes them
  (`finished_pod_retention_ms`).
- `symphony_runner_pods_waiting{reason}`: Pending pods that are waiting for capacity.
  `scheduling_gated` means not yet admitted by Kueue. `unschedulable` means no node fits.
- `symphony_runner_pod_start_seconds`: histogram, 1s to 6h, from pod creation until the runner
  container starts. It includes the Kueue wait, scheduling and image pulls. Only Pending→Running
  transitions the watch sees are recorded.
- `symphony_runner_pod_failures_total{reason}`: pods that turned Failed. The reason is the pod's
  own (`DeadlineExceeded`, `Evicted`), else the runner container's (`OOMKilled`, `Error`), with
  the exit code removed.
- `symphony_runner_launches_total{outcome}` (`started`, `failed`) and
  `symphony_runner_launch_failures_total{reason}`. The failure reason is a bounded step or status:
  `settings`, `runner_config`, `render`, `kube_client`, `http_<status>`, `transport`, `watcher`
  or `other`.
- `symphony_runner_janitor_deletions_total{kind}` (`pod`, `secret`).
- `symphony_runner_pod_watch_reconnects_total{reason}`. `closed` is the API server's normal
  five-minute watch timeout. `gone` is a 410 and triggers a relist. The others are
  `http_<status>`, `not_found`, `watch_error` (another `ERROR` event), `invalid_event`,
  `transport`, `crashed` (the watch task died) and `list_<reason>` for a failed list.
- `symphony_runner_pod_watch_synced`: 1 while the pod cache is trusted.
- `symphony_runner_pod_status_checks_total{source}`: where each run watcher's pod check was
  answered. `cache` is the pod cache. `miss` is a GET for a pod the cache does not have, and
  `stale` is a GET while the cache is not trusted. Many `stale` checks mean the watch is down
  and the API server is being polled again.

### Label cardinality at 1000 runs

- `symphony_run_cpu_percent`, `symphony_run_memory_bytes` (`issue`, `backend`, `stage`) and
  `symphony_run_tokens_per_minute` (`issue`, `backend`) keep the existing per-run design. They are gauges that are
  replaced on every sample, so only running runs have series: about 3000 at 1000 concurrent runs,
  and none left over once a run ends. Dashboards rely on them for per-issue drill-down.
- Every other series is labelled only by bounded values: backend, stage, phase, reason, outcome
  and source. Run ids and pod names are never labels. Reason labels are reduced to fixed sets
  (HTTP status, a step, the pod's reason word), never free text.

## Reading it from the VM

```bash
curl -s localhost:4000/metrics | grep symphony_run_
curl -s localhost:4000/metrics | grep symphony_linear_
curl -s localhost:4000/metrics | grep symphony_git_
```

If the endpoint requires the API token:

```bash
curl -s -H "Authorization: Bearer $SYMPHONY_API_TOKEN" localhost:4000/metrics | grep symphony_run_
```

Useful PromQL recipes (adjust `job`/`instance` to your scrape config):

```promql
# Per-agent average memory, MiB
avg by (issue) (symphony_run_memory_bytes) / 1024 / 1024

# Per-agent p95 memory across all observations since start
histogram_quantile(0.95, sum by (le) (rate(symphony_run_memory_bytes_distribution_bucket[1h]))) / 1024 / 1024

# Fleet p50/p95 CPU, in percent of one CPU
histogram_quantile(0.50, sum by (le) (rate(symphony_run_cpu_percent_distribution_bucket[1h])))
histogram_quantile(0.95, sum by (le) (rate(symphony_run_cpu_percent_distribution_bucket[1h])))

# Tokens/min per run, and fleet p95 over the last hour
symphony_run_tokens_per_minute
quantile_over_time(0.95, symphony_run_tokens_per_minute[1h])

# Linear requests/min per running agent
sum(rate(symphony_linear_requests_total[5m])) / max(symphony_runs_sampled)

# Runner pods by phase, and Kueue backlog
sum by (phase) (symphony_runner_pods)
symphony_runner_pods_waiting{reason="scheduling_gated"}

# p95 pod start latency (creation to running) over the last hour
histogram_quantile(0.95, sum by (le) (rate(symphony_runner_pod_start_seconds_bucket[1h])))

# API GETs the pod watch saves: share of watcher checks answered from the cache
sum(rate(symphony_runner_pod_status_checks_total{source="cache"}[5m]))
  / sum(rate(symphony_runner_pod_status_checks_total[5m]))

# Tokens per minute by backend, tool error ratio, run outcomes
sum by (backend) (rate(symphony_agent_tokens_total{type!="cached_input"}[5m])) * 60
sum(rate(symphony_agent_tool_calls_total{outcome="error"}[1h])) / sum(rate(symphony_agent_tool_calls_total[1h]))
sum by (outcome) (increase(symphony_agent_runs_total[1d]))

# Git operations per agent start
sum(rate(symphony_git_operations_total{operation="workspace_create"}[15m]))
  / sum(rate(symphony_git_operations_total{operation="cache_clone_or_fetch"}[15m]))
```

The distributions are process-lifetime histograms, so use `rate(...)` over a recent window rather
than the raw cumulative counts when comparing time periods.

## What we need before sizing Kubernetes

- [ ] Per-agent CPU p50/p95, from `symphony_run_cpu_percent_distribution`.
- [ ] Per-agent memory p50/p95, from `symphony_run_memory_bytes_distribution`.
- [ ] Per-agent tokens/min p50/p95, from `symphony_run_tokens_per_minute`.
- [ ] Linear requests/min per agent, from `symphony_linear_requests_total` and `symphony_runs_sampled`.
- [ ] Git operations per agent start, from `symphony_git_operations_total`.
- [ ] Peak values during a representative batch, not just steady state, so node requests/limits and
      overcommit ratios have headroom.
