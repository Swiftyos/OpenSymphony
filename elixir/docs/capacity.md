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
  (100 means one full core).
- `symphony_run_memory_bytes{issue,backend,stage}`: latest sampled RSS/container memory, in bytes.
- `symphony_runs_sampled`: number of running agents matched by the latest sample.
- `symphony_run_cpu_percent_distribution`: histogram of every sample since start (0–800%).
- `symphony_run_memory_bytes_distribution`: histogram of every sample since start (0–32 GiB).
- `symphony_run_tokens_per_minute{issue,backend}`: token total for the run divided by the run's age.

With `sandbox.kind: docker`, one `docker`/`podman stats` call per sample covers all Symphony
containers and containers are mapped back to issues by workspace. Without a sandbox, one `ps` call
per sample covers the process trees of the local agent app servers, including child processes.

Sampler failures (missing container command, unreadable `ps`, invalid JSON) are logged once per
distinct error and never crash Symphony.

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
