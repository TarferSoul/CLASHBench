#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
mkdir -p "$A_STATE_DIR" "$(dirname "$A_TRUST_FILE")"
rm -f "$A_STOP_FILE" "$A_SERVICE_PID_FILE" "$A_PRODUCER_PID_FILE" "$A_METRICS_FILE" "$A_EVENTS_FILE" "$A_PROGRESS_FILE"
python3 "$ROOT/a/enrichment_service.py" > "$A_STATE_DIR/service.log" 2>&1 &
service_pid=$!
printf '%s\n' "$service_pid" > "$A_SERVICE_PID_FILE"
ready=0
for _ in $(seq 1 80); do
  if python3 - "$A_HOST" "$A_PORT" "$A_SERVICE_NAME" >/dev/null 2>&1 <<'PY'
import json, sys, urllib.request
host, port, service = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=0.3) as response:
    data = json.load(response)
assert data.get("ready") is True and data.get("service") == service
PY
  then
    ready=1
    break
  fi
  sleep 0.1
done
if [ "$ready" != 1 ]; then
  echo "SETUP_FAIL=SERVICE_NOT_READY" >&2
  tail -100 "$A_STATE_DIR/service.log" >&2 || true
  exit 3
fi
CASE_PRIVATE_ROOT="$ROOT" \
  A_HOST="$A_HOST" A_PORT="$A_PORT" A_STOP_FILE="$A_STOP_FILE" A_PROGRESS_FILE="$A_PROGRESS_FILE" \
  A_PRODUCER_THREADS="$A_PRODUCER_THREADS" PRIVATE_DOCS_FILE="$PRIVATE_DOCS_FILE" \
  python3 "$ROOT/a/index_producer.py" > "$A_STATE_DIR/producer.log" 2>&1 &
producer_pid=$!
printf '%s\n' "$producer_pid" > "$A_PRODUCER_PID_FILE"
ready=0
for _ in $(seq 1 100); do
  if CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >/tmp/search_enrichment_status_a.txt 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
if [ "$ready" != 1 ]; then
  echo "SETUP_FAIL=PRODUCER_NOT_READY" >&2
  cat /tmp/search_enrichment_status_a.txt >&2 || true
  tail -80 "$A_STATE_DIR/producer.log" >&2 || true
  exit 3
fi
cat /tmp/search_enrichment_status_a.txt
echo "A_STARTED service_pid=$service_pid producer_pid=$producer_pid"
