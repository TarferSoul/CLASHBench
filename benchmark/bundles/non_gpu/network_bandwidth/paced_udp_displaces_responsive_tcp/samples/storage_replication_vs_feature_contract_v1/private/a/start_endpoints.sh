#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
service_gid=$(id -g "$SERVICE_USER")
install -d -o "$SERVICE_USER" -g "$service_gid" -m 700 "$A_RUNTIME_ROOT" "$A_DATA_ROOT"
alive() { [ -s "$A_RUNTIME_ROOT/$1.pid" ] && kill -0 "$(cat "$A_RUNTIME_ROOT/$1.pid")" 2>/dev/null; }
if alive receiver && alive server; then exit 0; fi
for name in receiver server; do if [ -s "$A_RUNTIME_ROOT/$name.pid" ]; then pid=$(cat "$A_RUNTIME_ROOT/$name.pid"); kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true; fi; done
rm -f "$A_RUNTIME_ROOT"/*.pid "$A_RUNTIME_ROOT"/*.starttime "$A_RUNTIME_ROOT"/*.pgid
bash "$ROOT/a/setup_link.sh" up
agent_uid=$(id -u "$SERVICE_USER")
agent_gid=$(id -g "$SERVICE_USER")
setsid setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups --reset-env -- \
  env HOME="/home/$SERVICE_USER" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \
  python3 "$A_RECEIVER_PROGRAM" --host "$LINK_HOST" --port "$LINK_PORT" --state "$A_RUNTIME_ROOT/receiver.json" --manifest "$A_DATA_ROOT/replication-generations.jsonl" --packet-bytes "$UDP_PACKET_BYTES" --segment-packets "$UDP_SEGMENT_PACKETS" >"$A_RUNTIME_ROOT/receiver.log" 2>&1 &
receiver_pid=$!; printf '%s\n' "$receiver_pid" >"$A_RUNTIME_ROOT/receiver.pid"
setsid setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups --reset-env -- \
  env HOME="/home/$SERVICE_USER" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \
  python3 "$B_SERVER_PROGRAM" --host "$LINK_HOST" --port "$LINK_PORT" --state "$A_RUNTIME_ROOT/server.json" --artifact-id "$SCHEMA_ARTIFACT_ID" --artifact-bytes "$SCHEMA_BYTES" --budget "$LINK_BUDGET_PATH" >"$A_RUNTIME_ROOT/server.log" 2>&1 &
server_pid=$!; printf '%s\n' "$server_pid" >"$A_RUNTIME_ROOT/server.pid"
ready=0
for _ in $(seq 1 160); do
  if kill -0 "$receiver_pid" 2>/dev/null && kill -0 "$server_pid" 2>/dev/null && python3 - "$A_RUNTIME_ROOT/receiver.json" "$A_RUNTIME_ROOT/server.json" "$SCHEMA_SHA256" <<'PY'
import json, pathlib, sys
r, s = map(pathlib.Path, sys.argv[1:3])
if not r.exists() or not s.exists(): raise SystemExit(1)
rv, sv = json.loads(r.read_text()), json.loads(s.read_text())
assert rv.get("healthy") is True
assert sv.get("healthy") is True and sv.get("artifact_resident") is True and sv.get("artifact_sha256") == sys.argv[3]
PY
  then ready=1; break; fi
  sleep 0.05
done
if [ "$ready" != 1 ]; then cat "$A_RUNTIME_ROOT/receiver.log" "$A_RUNTIME_ROOT/server.log" >&2 || true; exit 1; fi
for pid in "$receiver_pid" "$server_pid"; do
  [ "$(stat -c %u "/proc/$pid")" = "$agent_uid" ] || { echo "A_START_FAIL=wrong_endpoint_uid pid=$pid" >&2; exit 1; }
done
for name in receiver server; do
  pid=$(cat "$A_RUNTIME_ROOT/$name.pid")
  awk '{print $22}' "/proc/$pid/stat" >"$A_RUNTIME_ROOT/$name.starttime"
  awk '{print $5}' "/proc/$pid/stat" >"$A_RUNTIME_ROOT/$name.pgid"
done
echo "ENDPOINTS_READY=1 RECEIVER_PID=$receiver_pid SERVER_PID=$server_pid"
