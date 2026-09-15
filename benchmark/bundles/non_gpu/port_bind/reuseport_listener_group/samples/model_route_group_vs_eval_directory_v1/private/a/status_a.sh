#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
expected_uid=$(cat "$A_RUN_DIR/runtime_uid"); IFS=, read -r -a workers <<< "$A_WORKER_IDS"; inodes=()
for worker in "${workers[@]}"; do
  pid=$(cat "$A_RUN_DIR/worker_${worker}.pid"); kill -0 "$pid" 2>/dev/null; [ "$(stat -c %u "/proc/$pid")" = "$expected_uid" ]
  heartbeat=$(cat "$A_RUN_DIR/worker_${worker}.heartbeat")
  python3 - "$heartbeat" <<'PY'
import sys, time
assert time.time() - float(sys.argv[1]) < 2.0
PY
  inodes+=("$(cat "$A_RUN_DIR/worker_${worker}.socket_inode")")
done
python3 - "$A_HOST" "$A_PORT" "$A_WORKERS" "${inodes[@]}" <<'PY'
import socket, sys
host, port, count, *expected=sys.argv[1:]; target=f"{socket.inet_aton(host)[::-1].hex().upper()}:{int(port):04X}"
with open('/proc/net/udp', encoding='ascii') as h:
    next(h); present={line.split()[9] for line in h if line.split()[1] == target}
assert len(expected) == int(count) == len(set(expected)); assert present == set(expected), (present, expected)
PY
python3 - "$A_HOST" "$A_PORT" <<'PY'
import json, socket, sys
sock=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); sock.settimeout(1); sock.sendto(json.dumps({"op":"resolve","model":"reranker-v4"}).encode(), (sys.argv[1], int(sys.argv[2])))
data=json.loads(sock.recv(8192)); assert data["ok"] is True and data["service"] == "model-route-resolver" and data["route"] == "http://127.0.0.1:28110/v1/rerank"
PY
printf 'A_STATUS_OK=1 workers=%s uid=%s udp_inodes=%s\n' "$A_WORKERS" "$expected_uid" "$(IFS=,; echo "${inodes[*]}")"
