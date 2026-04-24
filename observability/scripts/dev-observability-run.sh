#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

if [[ -z "${DEV_ID:-}" ]]; then
    echo "DEV_ID is required. Example: DEV_ID=ryan $0 cargo run -p cli -- run ..." >&2
    exit 1
fi

if [[ "$#" -eq 0 ]]; then
    echo "pass the command to run after the wrapper" >&2
    exit 1
fi

log_dir="${repo_root}/.workspace/observability/logs"
target_dir="${repo_root}/.workspace/observability/vmagent/targets"
mkdir -p "$log_dir"
mkdir -p "$target_dir"
log_file="${log_dir}/${DEV_ID}.jsonl"

allocate_metrics_port() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 is required to allocate a free metrics port. Set AGENT_METRICS_BIND_ADDR explicitly to bypass allocation." >&2
        return 1
    fi

    python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("", 0))
    print(sock.getsockname()[1])
PY
}

yaml_quote() {
    printf "'"
    printf "%s" "$1" | sed "s/'/''/g"
    printf "'"
}

safe_dev_id="$(printf "%s" "$DEV_ID" | LC_ALL=C tr -c 'A-Za-z0-9_.-' '_')"
if [[ -z "$safe_dev_id" ]]; then
    echo "DEV_ID must contain at least one filename-safe character" >&2
    exit 1
fi

export AGENT_OBSERVABILITY="${AGENT_OBSERVABILITY:-1}"
if [[ -z "${AGENT_METRICS_BIND_ADDR:-}" ]]; then
    metrics_port="$(allocate_metrics_port)"
    export AGENT_METRICS_BIND_ADDR="0.0.0.0:${metrics_port}"
else
    export AGENT_METRICS_BIND_ADDR
    metrics_port="${AGENT_METRICS_BIND_ADDR##*:}"
fi

if ! [[ "$metrics_port" =~ ^[0-9]+$ ]] || (( metrics_port < 1 || metrics_port > 65535 )); then
    echo "could not determine metrics port from AGENT_METRICS_BIND_ADDR=${AGENT_METRICS_BIND_ADDR}" >&2
    exit 1
fi

metrics_scrape_target="${AGENT_METRICS_SCRAPE_TARGET:-host.docker.internal:${metrics_port}}"
target_file="${target_dir}/${safe_dev_id}.$$.yml"
target_tmp="${target_file}.$$.$RANDOM.tmp"
{
    printf -- "- targets:\n"
    printf "    - %s\n" "$(yaml_quote "$metrics_scrape_target")"
    printf "  labels:\n"
    printf "    service: %s\n" "$(yaml_quote "agent-cli")"
    printf "    dev_env: %s\n" "$(yaml_quote "$DEV_ID")"
} > "$target_tmp"
mv "$target_tmp" "$target_file"

cleanup_metrics_target() {
    rm -f "$target_tmp" "$target_file"
}
trap cleanup_metrics_target EXIT

export AGENT_METRICS_PUSH_ENDPOINT="${AGENT_METRICS_PUSH_ENDPOINT:-http://127.0.0.1:11341/api/v1/import/prometheus}"
export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://127.0.0.1:11338}"
export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-grpc}"
export OTEL_TRACES_EXPORTER="${OTEL_TRACES_EXPORTER:-otlp}"
export OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-otlp}"
export OTEL_LOGS_EXPORTER="${OTEL_LOGS_EXPORTER:-otlp}"
export RUST_LOG="${RUST_LOG:-info}"

echo "dev_env=${DEV_ID}"
echo "metrics endpoint=${AGENT_METRICS_BIND_ADDR}"
echo "metrics scrape target=${metrics_scrape_target}"
echo "vmagent target file=${target_file}"
echo "metrics final push=${AGENT_METRICS_PUSH_ENDPOINT}"
echo "otlp endpoint=${OTEL_EXPORTER_OTLP_ENDPOINT} (${OTEL_EXPORTER_OTLP_PROTOCOL})"
echo "stderr json logs + codex_trace timeline -> ${log_file}"

"$@" 2> >(tee -a "$log_file" >&2)
