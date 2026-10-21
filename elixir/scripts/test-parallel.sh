#!/bin/sh
# Runs the ExUnit suite in parallel OS processes, one MIX_TEST_PARTITION each.
#
# Every partition gets its own TMPDIR (so workflow bootstrap files, workspaces
# and repo caches cannot collide) and, when SYMPHONY_TEST_DATABASE_URL is set,
# its own Postgres database. This is what `make test` / `make test-fast` /
# `make coverage` use; `mix test` remains the single-process entry point.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR/.." || exit 1

MIX_BIN=${MIX:-mix}
MODE=full
COVERAGE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    fast|--fast)
      MODE=fast
      shift
      ;;
    coverage|--coverage)
      COVERAGE=1
      shift
      ;;
    --partitions)
      PARTITIONS=${2:-}
      shift 2
      ;;
    --partitions=*)
      PARTITIONS=${1#*=}
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [ -z "${PARTITIONS:-}" ]; then
  PARTITIONS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
  [ "$PARTITIONS" -gt 8 ] && PARTITIONS=8
fi

case "$PARTITIONS" in
  ''|*[!0-9]*)
    echo "test-parallel: PARTITIONS must be a positive integer, got: $PARTITIONS" >&2
    exit 2
    ;;
esac
[ "$PARTITIONS" -lt 1 ] && PARTITIONS=1

TMP_ROOT="${TMPDIR:-/tmp}/symphony-test-${USER:-$(id -u)}"
# Use the physical path: on macOS /tmp and /var/folders are symlinks into
# /private, and the workspace path-safety checks compare canonical paths.
mkdir -p "$TMP_ROOT"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
mkdir -p "$TMP_ROOT" || exit 1
RUN_DIR=$(mktemp -d "$TMP_ROOT/run.XXXXXX") || exit 1
run_started_at=$(date +%s)

partition_database_url() {
  # Append _p<n> to the database name, keeping any query string.
  base=$1
  n=$2
  case "$base" in
    *\?*)
      prefix=${base%%\?*}
      query=${base#*\?}
      printf '%s_p%s?%s' "$prefix" "$n" "$query"
      ;;
    *)
      printf '%s_p%s' "$base" "$n"
      ;;
  esac
}

echo "test-parallel: $PARTITIONS partition(s), mode=$MODE"
echo "test-parallel: TMPDIR per partition under $RUN_DIR/tmp"

# Compile once before the partitions race to write the same build.
if ! MIX_ENV=test "$MIX_BIN" compile >"$RUN_DIR/compile.log" 2>&1; then
  cat "$RUN_DIR/compile.log"
  exit 1
fi

if [ -n "${SYMPHONY_TEST_DATABASE_URL:-}" ]; then
  echo "test-parallel: preparing per-partition Postgres databases"
  if ! MIX_ENV=test "$MIX_BIN" run --no-start scripts/ensure_test_databases.exs "$PARTITIONS" >"$RUN_DIR/databases.log" 2>&1; then
    cat "$RUN_DIR/databases.log"
    exit 1
  fi
fi

if [ "$COVERAGE" = 1 ]; then
  # `mix test.coverage` imports every coverdata file; stale exports from earlier
  # runs would overwrite this run's partial results.
  rm -f cover/*.coverdata
fi

run_partition() {
  n=$1
  shift
  # Under this run's directory, so concurrent runs (other worktrees) never
  # share or wipe each other's partition TMPDIRs.
  part_tmp="$RUN_DIR/tmp/$n"
  mkdir -p "$part_tmp"

  (
    export TMPDIR="$part_tmp"
    export MIX_TEST_PARTITION="$n"
    [ "$COVERAGE" = 1 ] && export SYMPHONY_COVERAGE_PARTITION=1
    if [ -n "${SYMPHONY_TEST_DATABASE_URL:-}" ]; then
      SYMPHONY_TEST_DATABASE_URL=$(partition_database_url "$SYMPHONY_TEST_DATABASE_URL" "$n")
      export SYMPHONY_TEST_DATABASE_URL
    fi

    args="test --partitions $PARTITIONS"
    [ "$MODE" = fast ] && args="$args --exclude slow"
    [ "$COVERAGE" = 1 ] && args="$args --cover --export-coverage partition-$n"

    started_at=$(date +%s)
    # Fixed flags above are deliberately word-split; "$@" preserves test args.
    # shellcheck disable=SC2086
    "$MIX_BIN" $args "$@" >"$RUN_DIR/$n.log" 2>&1
    status=$?
    ended_at=$(date +%s)
    printf '%s\n' "$status" >"$RUN_DIR/$n.status"
    printf '%s\n' "$((ended_at - started_at))" >"$RUN_DIR/$n.seconds"
    exit "$status"
  )
}

pids=""

n=1
while [ "$n" -le "$PARTITIONS" ]; do
  run_partition "$n" "$@" &
  pids="$pids $!"
  n=$((n + 1))
done

failed=0
for pid in $pids; do
  wait "$pid" || failed=1
done

for n in $(
  n=1
  while [ "$n" -le "$PARTITIONS" ]; do
    printf '%s\n' "$n"
    n=$((n + 1))
  done
); do
  status_file="$RUN_DIR/$n.status"
  status=$(cat "$status_file" 2>/dev/null || echo 1)
  [ "$status" -ne 0 ] && failed=1

  echo
  echo "===== partition $n ====="
  cat "$RUN_DIR/$n.log"
done

if [ "$COVERAGE" = 1 ]; then
  echo
  echo "===== merged coverage ====="
  MIX_ENV=test "$MIX_BIN" test.coverage
  coverage_status=$?
  [ "$coverage_status" -ne 0 ] && failed=1
fi

echo
echo "===== parallel summary ====="
n=1
total_tests=0
total_failures=0
total_skipped=0
total_seconds=0
while [ "$n" -le "$PARTITIONS" ]; do
  summary_line=$(grep -E '[0-9]+ tests, [0-9]+ failures?' "$RUN_DIR/$n.log" | tail -1 || true)
  seconds=$(cat "$RUN_DIR/$n.seconds" 2>/dev/null || echo 0)
  status=$(cat "$RUN_DIR/$n.status" 2>/dev/null || echo 1)
  printf 'partition %s: %s (%ss, exit %s)\n' "$n" "${summary_line:-no summary}" "$seconds" "$status"

  if [ -n "$summary_line" ]; then
    counts=$(printf '%s\n' "$summary_line" | awk '{
      tests = $1
      failures = $3
      skipped = 0
      for (i = 1; i <= NF; i++) if ($i == "skipped") skipped = $(i - 1)
      printf "%d %d %d", tests, failures, skipped
    }')
    # shellcheck disable=SC2086
    set -- $counts
    total_tests=$((total_tests + $1))
    total_failures=$((total_failures + $2))
    total_skipped=$((total_skipped + $3))
  fi

  total_seconds=$((total_seconds + seconds))
  n=$((n + 1))
done

printf 'total: %s tests, %s failures, %s skipped across %s partitions\n' \
  "$total_tests" "$total_failures" "$total_skipped" "$PARTITIONS"
printf 'wall time: %ss (partition time summed: %ss)\n' "$(($(date +%s) - run_started_at))" "$total_seconds"

if [ "$failed" -ne 0 ]; then
  echo "test-parallel: logs kept in $RUN_DIR" >&2
  echo "test-parallel: FAILED" >&2
  exit 1
fi

rm -rf "$RUN_DIR"
echo "test-parallel: PASSED"
