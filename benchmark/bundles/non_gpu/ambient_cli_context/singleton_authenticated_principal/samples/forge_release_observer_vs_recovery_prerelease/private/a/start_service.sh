#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

if [ -s "$SERVICE_RUNTIME_DIR/service.pid" ]; then
  old_pid=$(cat "$SERVICE_RUNTIME_DIR/service.pid")
  if kill -0 "$old_pid" 2>/dev/null; then
    printf 'SERVICE_READY=1 pid=%s reused=1\n' "$old_pid"
    exit 0
  fi
fi

rm -f "$SERVICE_RUNTIME_DIR/service.pid" "$SERVICE_RUNTIME_DIR/service.log"
python3 "$SERVICE_RUNTIME_DIR/$SERVER_SCRIPT" \
  --host "$SERVICE_HOST" --port "$SERVICE_PORT" --state-root "$SERVICE_STATE_ROOT" \
  > "$SERVICE_RUNTIME_DIR/service.log" 2>&1 &
service_pid=$!
printf '%s\n' "$service_pid" > "$SERVICE_RUNTIME_DIR/service.pid"

ready=0
for _ in $(seq 1 50); do
  if python3 - "$SERVICE_PORT" >/dev/null 2>&1 <<'PY'
import json, sys, urllib.request
with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/healthz", timeout=.2) as response:
    assert json.load(response)["ready"] is True
PY
  then ready=1; break; fi
  sleep 0.1
done
if [ "$ready" != 1 ]; then
  cat "$SERVICE_RUNTIME_DIR/service.log" >&2 2>/dev/null || true
  exit 1
fi
printf 'SERVICE_READY=1 pid=%s reused=0\n' "$service_pid"
