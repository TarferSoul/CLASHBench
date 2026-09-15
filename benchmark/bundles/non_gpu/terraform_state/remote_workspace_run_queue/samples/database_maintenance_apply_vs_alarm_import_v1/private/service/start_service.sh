#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?set PRIVATE_CASE}"
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"

mkdir -p "$STATE_DIR"
chown root:root "$STATE_DIR"
chmod 700 "$STATE_DIR"
if [ -s "$SERVICE_PID_FILE" ]; then
  old_pid=$(cat "$SERVICE_PID_FILE")
  kill "$old_pid" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 "$old_pid" 2>/dev/null || break; sleep 0.1; done
fi
python3 "$PRIVATE_CASE/data/control_plane.py" reset --config "$PRIVATE_CASE/fixture.json" --state-dir "$STATE_DIR"
python3 "$PRIVATE_CASE/data/control_plane.py" serve --config "$PRIVATE_CASE/fixture.json" --state-dir "$STATE_DIR" --port "$WORKSPACE_PORT" > "$STATE_DIR/service.log" 2>&1 &
service_pid=$!
printf '%s\n' "$service_pid" > "$SERVICE_PID_FILE"
ready=0
for _ in $(seq 1 80); do
  if python3 - "$WORKSPACE_URL/health" <<'PY' >/dev/null 2>&1
import json, sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=1) as response:
    assert json.loads(response.read())["ok"] is True
PY
  then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] || { cat "$STATE_DIR/service.log" >&2; exit 1; }
printf 'SERVICE_READY=1 pid=%s workspace=%s\n' "$service_pid" "$WORKSPACE_NAME"
