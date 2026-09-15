#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
expected_uid=$(cat "$A_RUN_DIR/runtime_uid")
IFS=, read -r -a workers <<< "$A_WORKER_IDS"
inodes=()
for worker in "${workers[@]}"; do
  pid=$(cat "$A_RUN_DIR/worker_${worker}.pid")
  kill -0 "$pid" 2>/dev/null
  [ "$(stat -c %u "/proc/$pid")" = "$expected_uid" ]
  heartbeat=$(cat "$A_RUN_DIR/worker_${worker}.heartbeat")
  python3 - "$heartbeat" <<'PY'
import sys, time
assert time.time() - float(sys.argv[1]) < 2.0
PY
  inodes+=("$(cat "$A_RUN_DIR/worker_${worker}.socket_inode")")
done
python3 - "$A_HOST" "$A_PORT" "$A_WORKERS" "${inodes[@]}" <<'PY'
import socket, sys
host, port, count, *expected = sys.argv[1:]
target = f"{socket.inet_aton(host)[::-1].hex().upper()}:{int(port):04X}"
with open("/proc/net/tcp", encoding="ascii") as handle:
    next(handle); present = {line.split()[9] for line in handle if line.split()[1] == target and line.split()[3] == "0A"}
assert len(expected) == int(count) == len(set(expected))
assert present == set(expected), (present, expected)
PY
python3 - "$A_HOST" "$A_PORT" <<'PY'
import json, sys, urllib.request
host, port = sys.argv[1], int(sys.argv[2])
for event, fields in (("build.started", ["run_id", "commit", "started_at"]), ("build.finished", ["run_id", "status", "duration_ms"])):
    with urllib.request.urlopen(f"http://{host}:{port}/v1/schema?event={event}", timeout=1) as response: data = json.load(response)
    assert data["ok"] is True and data["service"] == "telemetry-schema-registry" and data["fields"] == fields
PY
printf 'A_STATUS_OK=1 workers=%s uid=%s inodes=%s\n' "$A_WORKERS" "$expected_uid" "$(IFS=,; echo "${inodes[*]}")"
