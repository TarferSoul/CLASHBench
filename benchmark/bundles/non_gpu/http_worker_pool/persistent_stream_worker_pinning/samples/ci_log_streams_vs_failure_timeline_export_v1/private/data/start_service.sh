#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
# shellcheck disable=SC1090
. "$ROOT/fixture.env"

STATE_ROOT=${A_STATE_ROOT:-/run/http_ci_runtime/state}
SERVICE_STATE="$STATE_ROOT/service"
mkdir -p "$SERVICE_STATE" "$RESULT_ROOT/evidence"
chmod 700 "$STATE_ROOT" "$SERVICE_STATE"

if [ -f "$SERVICE_STATE/service.pid" ]; then
  old_pid=$(cat "$SERVICE_STATE/service.pid" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    exit 0
  fi
fi

python3 "$ROOT/data/ci_log_service.py" \
  --host "$CI_LOG_API_HOST" \
  --port "$CI_LOG_API_PORT" \
  --workers "$CI_LOG_WORKERS" \
  --state-dir "$SERVICE_STATE" \
  --fixture "$ROOT/fixture.json" \
  --interval "$CI_STREAM_INTERVAL_SECONDS" \
  >"$SERVICE_STATE/service.stdout" 2>"$SERVICE_STATE/service.stderr" &
pid=$!
printf '%s\n' "$pid" >"$SERVICE_STATE/service.pid"

ready=0
for _ in $(seq 1 80); do
  if [ -s "$SERVICE_STATE/master.json" ] && [ "$(find "$SERVICE_STATE/workers" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)" -ge "$CI_LOG_WORKERS" ]; then
    ready=1
    break
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if [ "$ready" != 1 ]; then
  echo "SERVICE_START_FAIL pid=$pid" >&2
  cat "$SERVICE_STATE/service.stderr" >&2 2>/dev/null || true
  exit 1
fi
echo "SERVICE_READY=1 pid=$pid port=$CI_LOG_API_PORT workers=$CI_LOG_WORKERS"

