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

vmagent supports scraping multiple Symphony instances running on the host. By default it scrapes
`host.docker.internal:4000` and `host.docker.internal:4001`, each tagged with its own
`instance_name` label so metrics from different instances can be distinguished in Grafana.

To add or rename instances, edit the `symphony` job in `vmagent/prometheus.yml` and restart the
vmagent container so the new bind-mounted config is picked up.

The local contract for each instance:

- run it on a unique port (e.g. `4000`, `4001`, …), either via `--port <port>` or
  `server.port: <port>` in that instance's `symphony.yml`
- when scraping from the Docker-based local observability stack, set `server.host: 0.0.0.0`
  so `vmagent` can reach the endpoint through `host.docker.internal`

When the server is enabled, Symphony exposes:

- LiveView dashboard at `/`
- JSON state endpoints under `/api/v1/*`
- Prometheus exposition text at `/metrics`

If no Symphony instance is listening on a scraped port (by default `0.0.0.0:4000` or
`0.0.0.0:4001`), the limit and billing-cycle panels in `Account Usage` stay empty even though
provider token panels may still populate from direct OTEL traffic.
