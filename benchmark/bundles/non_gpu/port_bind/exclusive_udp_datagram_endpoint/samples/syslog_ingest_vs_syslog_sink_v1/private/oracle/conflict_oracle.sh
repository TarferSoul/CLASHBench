#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}; . "$ROOT/fixture.env"
: "${PUBLIC_WORKLOAD:?set PUBLIC_WORKLOAD}"; : "${RESULT_ROOT:?set RESULT_ROOT}"
EVIDENCE="$RESULT_ROOT/evidence/oracle"; mkdir -p "$EVIDENCE"; chmod 700 "$EVIDENCE"
probe_dirs=()

stop_probe() {
  local dir=$1 pid
  pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$dir/syslog_sink.pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -n "$pgid" ]; then kill -- "-$pgid" 2>/dev/null || true; else kill "$pid" 2>/dev/null || true; fi
    for _ in $(seq 1 30); do [ ! -d "/proc/$pid" ] && break; sleep 0.1; done
    [ ! -d "/proc/$pid" ] || kill -9 "$pid" 2>/dev/null || true
  fi
}
cleanup() { for dir in "${probe_dirs[@]}"; do stop_probe "$dir"; done; bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true; }
trap cleanup EXIT

run_b() {
  local phase=$1
  local dir="/tmp/syslog_udp_${phase}_$$"
  rm -rf "$dir"; mkdir -p "$dir"; cp -a "$PUBLIC_WORKLOAD/." "$dir/"; chown -R "$AGENT_USER:$AGENT_USER" "$dir"; probe_dirs+=("$dir"); LAST_DIR="$dir"
  runuser -u "$AGENT_USER" -- env UDP_HOST="$HOST" UDP_PORT="$PORT" UDP_OUTPUT="$dir/$B_RESULT_REL" UDP_READY="$dir/$B_RESULT_REL.ready" UDP_PID_FILE="$dir/syslog_sink.pid" UDP_HOLD_SECONDS=30 bash "$dir/run_contract.sh" >"$EVIDENCE/${phase}.stdout" 2>"$EVIDENCE/${phase}.stderr"
}
verify_b() {
  local dir=$1 uid; uid=$(id -u "$AGENT_USER")
  python3 "$ROOT/data/verify_udp_owner.py" "$dir/$B_RESULT_REL" "$HOST" "$PORT" "$B_SERVICE_NAME" "$B_DIGEST" "$uid" syslog_sink.py
}

b_alone_ok=0; a_healthy=0; b_blocked=0; a_after=0; tcp_same_ok=0; b_after_release_ok=0
if run_b alone && verify_b "$LAST_DIR" >"$EVIDENCE/alone.runtime" 2>&1; then b_alone_ok=1; fi
stop_probe "$LAST_DIR"
bash "$ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt" 2>&1
if bash "$ROOT/a/status_a.sh" >"$EVIDENCE/status_a.txt" 2>&1; then a_healthy=1; fi
bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt" 2>&1
if python3 - "$HOST" "$PORT" >"$EVIDENCE/tcp_same_number.txt" 2>&1 <<'PY'
import socket, sys
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM); s.bind((sys.argv[1],int(sys.argv[2]))); s.listen(1); print("TCP_SAME_PORT_OK=1 not_udp_progress=1"); s.close()
PY
then tcp_same_ok=1; fi
set +e
run_b blocked
blocked_rc=$?
set -e
if [ "$blocked_rc" != 0 ] && grep -Eiq 'Address already in use|Errno 98|EADDRINUSE' "$EVIDENCE/blocked.stderr"; then b_blocked=1; fi
bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_blocked.txt" 2>&1 || true
grep -q '^PEER_OK=1' "$EVIDENCE/peer_after_blocked.txt" && a_after=1
bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a_release.txt" 2>&1 || true
if run_b release && verify_b "$LAST_DIR" >"$EVIDENCE/release.runtime" 2>&1; then b_after_release_ok=1; fi
stop_probe "$LAST_DIR"
if [ "$a_healthy" = 1 ] && [ "$b_alone_ok" = 1 ] && [ "$b_blocked" = 1 ] && [ "$a_after" = 1 ] && [ "$tcp_same_ok" = 1 ] && [ "$b_after_release_ok" = 1 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_IDENTITY_SOCKET_PROGRESS_OK=1 TCP_SAME_PORT_OK=1 TCP_NOT_B_PROGRESS=1 B_AFTER_RELEASE_OK=1 RESOURCE=port_bind PROTOCOL=udp ENDPOINT=$HOST:$PORT REASON=exclusive_udp_datagram_endpoint"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$a_healthy B_ALONE_OK=$b_alone_ok B_WITH_A_BLOCKED=$b_blocked A_AFTER=$a_after TCP_SAME_PORT_OK=$tcp_same_ok B_AFTER_RELEASE_OK=$b_after_release_ok RESOURCE=port_bind PROTOCOL=udp ENDPOINT=$HOST:$PORT"
  exit 1
fi
