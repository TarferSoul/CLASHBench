#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
mkdir -p "$RUNTIME_DIR" /var/cbtrust
rm -f "$A_SERVICE_PID_FILE" "$A_PRODUCER_PID_FILE" "$A_PROGRESS_FILE" "$A_METRICS_FILE" "$A_EVENTS_FILE"
printf '%s\n' "$A_GENERATION" > "$A_GENERATION_FILE"
printf '%s\n' "$A_IDENTITY" > "$A_IDENTITY_FILE"
export A_HOST A_PORT A_SERVICE A_IDENTITY A_WORKERS A_QUEUE_CAPACITY A_REQUEST_SECONDS A_METRICS_FILE A_EVENTS_FILE A_GENERATION_FILE A_IDENTITY_FILE A_GENERATION
python3 "$ROOT/a/service.py" >"$RUNTIME_DIR/service.log" 2>&1 &
service_pid=$!
printf '%s\n' "$service_pid" > "$A_SERVICE_PID_FILE"
for _ in $(seq 1 60); do
  if python3 - "$A_HOST" "$A_PORT" <<'PY' >/dev/null 2>&1
import json, sys, urllib.request
with urllib.request.urlopen(f"http://{sys.argv[1]}:{sys.argv[2]}/healthz", timeout=0.3) as r:
    assert json.load(r).get("ready") is True
PY
  then break; fi
  kill -0 "$service_pid" 2>/dev/null || { echo "SERVICE_START_FAILED=1" >&2; exit 1; }
  sleep 0.05
done
if ! python3 - "$A_HOST" "$A_PORT" <<'PY' >/dev/null 2>&1
import json, sys, urllib.request
with urllib.request.urlopen(f"http://{sys.argv[1]}:{sys.argv[2]}/healthz", timeout=0.5) as r:
    assert json.load(r).get("service") == "billing-rules"
PY
then echo "SERVICE_NOT_READY=1" >&2; exit 1; fi
export A_PRODUCERS A_PROGRESS_FILE
python3 "$ROOT/a/reconciler.py" >"$RUNTIME_DIR/reconciler.log" 2>&1 &
printf '%s\n' "$!" > "$A_PRODUCER_PID_FILE"
echo "A_STARTED=1 service_pid=$service_pid producer_pid=$(cat "$A_PRODUCER_PID_FILE") generation=$A_GENERATION"
