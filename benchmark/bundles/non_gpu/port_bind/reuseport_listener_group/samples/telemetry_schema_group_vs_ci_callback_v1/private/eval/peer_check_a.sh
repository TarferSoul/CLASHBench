#!/usr/bin/env bash
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
[ -r "$A_TRUST_FILE" ] || { echo 'PEER_OK=0 reason=missing_trust'; exit 0; }
. "$A_TRUST_FILE"
same=1
IFS=, read -r -a workers <<< "$A_WORKER_IDS"
inodes=()
for worker in "${workers[@]}"; do
  key=$(printf '%s' "$worker" | tr '[:lower:]-' '[:upper:]_')
  eval "pid=\${A_${key}_PID:-}"; eval "start=\${A_${key}_STARTTIME:-}"; eval "uid=\${A_${key}_UID:-}"; eval "inode=\${A_${key}_SOCKET_INODE:-}"
  current_start=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
  current_uid=$(stat -c %u "/proc/$pid" 2>/dev/null || true)
  [ "$current_start" = "$start" ] && [ "$current_uid" = "$uid" ] || same=0
  heartbeat=$(cat "$A_RUN_DIR/worker_${worker}.heartbeat" 2>/dev/null || true)
  python3 - "$heartbeat" >/dev/null 2>&1 <<'PY' || same=0
import sys, time
assert time.time() - float(sys.argv[1]) < 2.0
PY
  inodes+=("$inode")
done
python3 - "$A_HOST" "$A_PORT" "${inodes[@]}" >/dev/null 2>&1 <<'PY' || same=0
import socket, sys
host, port, *expected = sys.argv[1:]
target = f"{socket.inet_aton(host)[::-1].hex().upper()}:{int(port):04X}"
with open("/proc/net/tcp", encoding="ascii") as handle:
    next(handle); present = {line.split()[9] for line in handle if line.split()[1] == target and line.split()[3] == "0A"}
assert present == set(expected)
PY
health=0
python3 - "$A_HOST" "$A_PORT" >/dev/null 2>&1 <<'PY' && health=1
import json, sys, urllib.request
with urllib.request.urlopen(f"http://{sys.argv[1]}:{int(sys.argv[2])}/v1/schema?event=build.finished", timeout=1) as response: data=json.load(response)
assert data["service"] == "telemetry-schema-registry" and data["ok"] is True
PY
if [ "$same" = 1 ] && [ "$health" = 1 ]; then
  echo "PEER_OK=1 original_group=1 workers=$A_WORKER_COUNT inodes=$A_SOCKET_INODES"
else
  echo "PEER_OK=0 original_group=$same health=$health expected_workers=$A_WORKER_COUNT"
fi
