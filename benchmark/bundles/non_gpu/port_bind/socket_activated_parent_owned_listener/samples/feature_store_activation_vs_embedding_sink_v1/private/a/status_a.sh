#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
. "$private_root/fixture.env"
parent_pid=$(cat "$A_PID_FILE")
kill -0 "$parent_pid"
[ "$(stat -c %u /proc/$parent_pid)" = "$(id -u "$AGENT_USER")" ]
if [ ! -s "$A_WORKER_PID_FILE" ]; then
  runuser -u "$AGENT_USER" -- kill -USR1 "$parent_pid"
fi
for _ in $(seq 1 50); do
  if [ -s "$A_WORKER_PID_FILE" ] && [ -s "$A_WORKER_INODE_FILE" ] && kill -0 "$(cat "$A_WORKER_PID_FILE")" 2>/dev/null; then
    python3 - "$LISTEN_ADDRESS" "$LISTEN_PORT" "$A_SERVICE" "$A_STATE_DIR" <<'PY'
import json, pathlib, sys, urllib.request
host, port, service, state = sys.argv[1:]
base = f"http://{host}:{port}"
with urllib.request.urlopen(base + "/healthz", timeout=0.6) as response:
    health = json.load(response)
assert health.get("service") == service and health.get("status") == "ready" and health.get("workspace") == "online-ranking"
with urllib.request.urlopen(base + "/v1/features?entity=user-1042", timeout=0.6) as response:
    features = json.load(response)
assert features.get("service") == service and features.get("features") == ["user-1042", "item-883"]
print(f"A_HEALTHY=1 parent_pid={pathlib.Path(state, 'parent.pid').read_text().strip()} worker_pid={pathlib.Path(state, 'worker.pid').read_text().strip()} generation={health['worker_generation']} feature_rows=2")
PY
    exit 0
  fi
  sleep 0.1
done
exit 1
