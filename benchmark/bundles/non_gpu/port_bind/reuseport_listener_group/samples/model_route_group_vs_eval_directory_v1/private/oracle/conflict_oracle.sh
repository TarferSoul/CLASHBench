#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
EVIDENCE_ROOT=${RESULT_ROOT:-/tmp/reuseport-udp-result}/evidence; mkdir -p "$EVIDENCE_ROOT"; chmod 700 "$EVIDENCE_ROOT"; b_pid=''; a_started=0
cleanup() { [ -z "$b_pid" ] || kill "$b_pid" 2>/dev/null || true; [ -z "$b_pid" ] || wait "$b_pid" 2>/dev/null || true; [ "$a_started" = 0 ] || bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true; }
trap cleanup EXIT
prepare_b() { rm -rf "$B_RUN_DIR"; install -d -m 0755 -o "$B_UID" -g "$B_GID" "$B_RUN_DIR"; }
start_b() {
  local label=$1 reuse=$2; prepare_b; python3 "$ROOT/data/b_server.py" "$B_HOST" "$B_PORT" "$B_RUN_DIR" "$B_UID" "$B_GID" "$reuse" >"$EVIDENCE_ROOT/${label}.log" 2>&1 & b_pid=$!
  for _ in $(seq 1 50); do [ -s "$B_RUN_DIR/ready" ] && kill -0 "$b_pid" 2>/dev/null && return 0; kill -0 "$b_pid" 2>/dev/null || break; sleep .1; done; return 1
}
stop_b() { [ -z "$b_pid" ] || kill "$b_pid" 2>/dev/null || true; [ -z "$b_pid" ] || wait "$b_pid" 2>/dev/null || true; b_pid=''; }
try_blocked() {
  local label=$1 reuse=$2; prepare_b; set +e; python3 "$ROOT/data/b_server.py" "$B_HOST" "$B_PORT" "$B_RUN_DIR" "$B_UID" "$B_GID" "$reuse" >"$EVIDENCE_ROOT/${label}.log" 2>&1; rc=$?; set -e
  printf '%s\n' "$rc" >"$EVIDENCE_ROOT/${label}.rc"; [ "$rc" = 42 ] && grep -Eq 'B_BIND_ERROR errno=(98|48)' "$EVIDENCE_ROOT/${label}.log"
}
b_alone=0; if start_b b_alone 0 && EXPECTED_B_UID=$B_UID bash "$ROOT/eval/task_check_b.sh" >"$EVIDENCE_ROOT/b_alone_contract.txt"; then b_alone=1; fi; stop_b
A_RUNTIME_USER=$SERVICE_USER bash "$ROOT/a/start_a.sh" >"$EVIDENCE_ROOT/a_start.txt"; a_started=1
bash "$ROOT/a/status_a.sh" >"$EVIDENCE_ROOT/a_status.txt"; bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE_ROOT/a_trust_capture.txt"; cp "$A_TRUST_FILE" "$EVIDENCE_ROOT/datagram_group_membership.txt"
ordinary=0; reuse=0; try_blocked b_with_a_ordinary 0 && ordinary=1; try_blocked b_with_a_reuseport 1 && reuse=1
a_healthy=0; bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE_ROOT/a_peer_after_attempts.txt"; grep -q '^PEER_OK=1' "$EVIDENCE_ROOT/a_peer_after_attempts.txt" && a_healthy=1
. "$A_TRUST_FILE"; bash "$ROOT/a/stop_a.sh" >"$EVIDENCE_ROOT/a_stop.txt"; a_started=0; group_released=0
python3 - "$A_HOST" "$A_PORT" "$A_SOCKET_INODES" <<'PY' && group_released=1
import socket, sys
host, port, raw=sys.argv[1], int(sys.argv[2]), sys.argv[3]; expected=set(raw.split(',')); target=f"{socket.inet_aton(host)[::-1].hex().upper()}:{port:04X}"
with open('/proc/net/udp', encoding='ascii') as h: next(h); present={line.split()[9] for line in h if line.split()[1] == target}
assert not (expected & present) and not present
PY
b_after=0; if [ "$group_released" = 1 ] && start_b b_after_release 0 && EXPECTED_B_UID=$B_UID bash "$ROOT/eval/task_check_b.sh" >"$EVIDENCE_ROOT/b_after_contract.txt"; then b_after=1; fi; stop_b
member_count=$(printf '%s' "$A_WORKER_IDS" | awk -F, '{print NF}'); inode_count=$(printf '%s' "$A_SOCKET_INODES" | awk -F, '{print NF}')
if [ "$b_alone" = 1 ] && [ "$ordinary" = 1 ] && [ "$reuse" = 1 ] && [ "$a_healthy" = 1 ] && [ "$group_released" = 1 ] && [ "$b_after" = 1 ] && [ "$member_count" = "$A_WORKERS" ] && [ "$inode_count" = "$A_WORKERS" ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 ORDINARY_BIND_BLOCKED=1 REUSEPORT_JOIN_BLOCKED=1 GROUP_MEMBERS=$member_count GROUP_INODES=$inode_count GROUP_RELEASED=1 B_AFTER_RELEASE_OK=1 RESOURCE=port_bind REASON=udp_reuseport_model_route_group"; exit 0
fi
echo "CONFLICT_OK=0 A_HEALTHY=$a_healthy B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=$ordinary ORDINARY_BIND_BLOCKED=$ordinary REUSEPORT_JOIN_BLOCKED=$reuse GROUP_RELEASED=$group_released B_AFTER_RELEASE_OK=$b_after RESOURCE=port_bind REASON=construction_contract_incomplete"; exit 1
