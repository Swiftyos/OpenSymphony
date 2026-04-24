# Observability

The local observability stack lives in this directory and starts Grafana, VictoriaMetrics,
VictoriaLogs, VictoriaTraces, Vector, and vmagent for a single developer machine.

## Start the stack

```bash
observability/scripts/dev-observability-up.sh
```

Endpoints:

- Grafana: `http://localhost:11337` (`admin` / `admin`)
- Vector OTLP gRPC: `http://localhost:11338`
- Vector OTLP HTTP: `http://localhost:11339`
- Vector API: `http://localhost:11340`
- VictoriaMetrics: `http://localhost:11341`
- VictoriaLogs: `http://localhost:11342`
- VictoriaTraces: `http://localhost:11343/select/vmui`

## Account Usage dashboard

Grafana now provisions an `Account Usage` dashboard in the `Symphony` folder.

It combines two telemetry sources:

- Provider telemetry for token usage:
  - Codex `codex.sse_event` logs from VictoriaLogs for account-aware token totals
  - Claude `api_request` logs from VictoriaLogs for account-aware token totals
- Symphony-exported account telemetry from `GET /metrics` for:
  - current session and weekly quota buckets
  - active usage-period rows from account state, backfilled from live rate-limit snapshots when persisted periods are missing
  - closed weekly/session usage periods loaded from `usage_periods.csv`

The dashboard includes:

- Per-account token totals for input, cache read, cache creation, output, and total
- Current session/weekly limit usage by account
- Weekly billing-cycle history aligned to each account reset boundary

## Symphony `/metrics`

vmagent scrapes Symphony from `host.docker.internal:4001`, so the local contract is:

- run Symphony with `--port 4001`, or
- set `server.port: 4001` in `symphony.yml`
- when scraping from the Docker-based local observability stack, set `server.host: 0.0.0.0`
  so `vmagent` can reach the endpoint through `host.docker.internal`

When the server is enabled, Symphony exposes:

- LiveView dashboard at `/`
- JSON state endpoints under `/api/v1/*`
- Prometheus exposition text at `/metrics`

If Symphony is not listening on `0.0.0.0:4001`, the limit and billing-cycle panels in
`Account Usage` stay empty even though provider token panels may still populate from direct OTEL
traffic.
