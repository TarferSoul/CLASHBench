#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
. "$ROOT/fixture.env"
: "${A_STATE_ROOT:?set A_STATE_ROOT}"

mkdir -p "$A_STATE_ROOT/logs" "$A_STATE_ROOT/service"
chmod 700 "$A_STATE_ROOT" "$A_STATE_ROOT/logs" "$A_STATE_ROOT/service"

python3 "$ROOT/data/release_control_service.py" \
  --host "$SERVICE_HOST" \
  --port "$SERVICE_PORT" \
  --workers "$WORKER_COUNT" \
  --state-dir "$A_STATE_ROOT" \
  >"$A_STATE_ROOT/logs/service.stdout" \
  2>"$A_STATE_ROOT/logs/service.stderr" &
service_pid=$!
printf '%s\n' "$service_pid" >"$A_STATE_ROOT/service.pid"

ready=0
for _ in $(seq 1 100); do
  if python3 - "$A_STATE_ROOT/service/workers.json" "$WORKER_COUNT" >/dev/null 2>&1 <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
want = int(sys.argv[2])
data = json.loads(path.read_text())
if len(data.get("workers", [])) != want:
    raise SystemExit(1)
PY
  then
    ready=1
    break
  fi
  if ! kill -0 "$service_pid" 2>/dev/null; then
    cat "$A_STATE_ROOT/logs/service.stderr" >&2 2>/dev/null || true
    exit 1
  fi
  sleep 0.1
done
[ "$ready" = 1 ] || { echo "SERVICE_START_FAILED=workers_not_ready" >&2; exit 1; }
echo "SERVICE_STARTED=1 pid=$service_pid port=$SERVICE_PORT workers=$WORKER_COUNT"

