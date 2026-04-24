#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

mkdir -p .workspace/observability/logs
mkdir -p .workspace/observability/vmagent/targets

docker compose -f observability/docker-compose.yml up -d

cat <<'EOF'
Local observability stack is starting.

Grafana:         http://localhost:11337   (admin / admin)
Vector Otel gRPC: http://localhost:11338
Vector Otel HTTP: http://localhost:11339
Vector API:      http://localhost:11340
VictoriaMetrics: http://localhost:11341
VictoriaLogs:    http://localhost:11342
VictoriaTraces:  http://localhost:11343/select/vmui

Next step:
  DEV_ID=<name> scripts/dev-observability-run.sh <command>
EOF
