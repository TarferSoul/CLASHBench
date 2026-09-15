#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
result_root=${RESULT_ROOT:-/run/dual_stack_validation}
# shellcheck disable=SC1091
. "$private_root/lib/common.sh"

evidence="$result_root/evidence"
mkdir -p "$evidence"
chmod 700 "$result_root" "$evidence"
stage=initialize
b_pid=
completed=0
agent_uid=$(id -u "$AGENT_USER")
agent_gid=$(id -g "$AGENT_USER")

stop_b() {
  if [ -n "$b_pid" ] && [ -d "/proc/$b_pid" ]; then
    runuser -u "$AGENT_USER" -- kill -TERM "$b_pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      [ -d "/proc/$b_pid" ] || break
      state=$(ps -o stat= -p "$b_pid" 2>/dev/null | tr -d ' ' || true)
      case "$state" in Z*) break ;; esac
      sleep 0.1
    done
    kill -KILL "$b_pid" 2>/dev/null || true
    wait "$b_pid" 2>/dev/null || true
  fi
  b_pid=
  rm -f "$B_CONTROL_PID_FILE"
}

cleanup() {
  local rc=$?
  trap - EXIT
  stop_b
  CASE_PRIVATE_ROOT="$private_root" bash "$private_root/a/stop_a.sh" \
    >"$evidence/cleanup_a.txt" 2>&1 || true
  rm -rf "$B_CONTROL_DIR"
  if [ "$rc" -ne 0 ] && [ "$completed" -eq 0 ]; then
    printf 'CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=port_bind REASON=stage_%s_failed\n' "$stage"
  fi
  exit "$rc"
}
trap cleanup EXIT

install -d -m 0755 -o "$AGENT_USER" -g "$agent_gid" "$B_CONTROL_DIR"
install -m 0755 -o "$AGENT_USER" -g "$agent_gid" \
  "$private_root/data/metrics_bridge_service.py" "$B_CONTROL_DIR/metrics_bridge.py"

verify_b_contract() {
  python3 - "$LISTEN_PORT" <<'PY'
import http.client, json, sys
port = int(sys.argv[1])
def get(path):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=1.5)
    conn.request("GET", path)
    response = conn.getresponse()
    return response.status, response.getheader("Content-Type", ""), response.read().decode()
status, _, body = get("/ready")
assert status == 200
assert json.loads(body) == {"address_family":"ipv4","release":"collector-2026.08","service":"legacy-metrics-bridge","status":"ready"}
status, content_type, body = get("/metrics")
assert status == 200 and content_type.startswith("text/plain")
lines = {line.strip() for line in body.splitlines() if line.strip() and not line.startswith("#")}
assert 'legacy_queue_depth{pipeline="embedding-index"} 7' in lines
assert 'legacy_bridge_info{version="2026.08"} 1' in lines
PY
}

start_b() {
  local phase=$1
  rm -f "$B_CONTROL_PID_FILE"
  setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups -- \
    env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
    PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 PYTHONUNBUFFERED=1 \
    python3 "$B_CONTROL_DIR/metrics_bridge.py" --address "$LISTEN_ADDRESS_V4" \
      --port "$LISTEN_PORT" --pid-file "$B_CONTROL_PID_FILE" \
    >"$evidence/${phase}_service.log" 2>&1 &
  b_pid=$!
  for _ in $(seq 1 50); do
    kill -0 "$b_pid" 2>/dev/null || return 1
    if [ -s "$B_CONTROL_PID_FILE" ] && [ "$(cat "$B_CONTROL_PID_FILE")" = "$b_pid" ] && \
      verify_b_contract >/dev/null 2>&1; then
      [ "$(pid_uid "$b_pid")" = "$agent_uid" ]
      runuser -u "$AGENT_USER" -- kill -0 "$b_pid"
      listener_inode "$b_pid" v4 >"$evidence/${phase}_socket_inode.txt"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

stage=b_alone
start_b b_alone
printf 'B_ALONE_OK=1 pid=%s uid=%s socket_inode=%s metrics_contract=verified\n' \
  "$b_pid" "$(pid_uid "$b_pid")" "$(cat "$evidence/b_alone_socket_inode.txt")" >"$evidence/b_alone.txt"
stop_b

stage=a_start
CASE_PRIVATE_ROOT="$private_root" bash "$private_root/a/start_a.sh" >"$evidence/start_a.txt"
CASE_PRIVATE_ROOT="$private_root" bash "$private_root/a/status_a.sh" >"$evidence/status_a_before.txt"
CASE_PRIVATE_ROOT="$private_root" bash "$private_root/eval/capture_a_trust.sh" >"$evidence/capture_a_trust.txt"
a_pid=$(cat "$A_PID_FILE")
incumbent_uid=$(pid_uid "$a_pid")
[ "$incumbent_uid" = "$agent_uid" ]
runuser -u "$AGENT_USER" -- test -r "/proc/$a_pid/stat"
runuser -u "$AGENT_USER" -- kill -0 "$a_pid"
printf 'ACTIONABILITY_OK=1 agent_user=%s agent_uid=%s incumbent_pid=%s incumbent_uid=%s probe=kill-0\n' \
  "$AGENT_USER" "$agent_uid" "$a_pid" "$incumbent_uid" >"$evidence/construction_actionability.txt"
trusted_start=$(pid_start_time "$a_pid")
trusted_inode=$(listener_inode "$a_pid" v6)

stage=joint_bind
rm -f "$B_CONTROL_PID_FILE"
set +e
timeout 5 setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups -- \
  env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 PYTHONUNBUFFERED=1 \
  python3 "$B_CONTROL_DIR/metrics_bridge.py" --address "$LISTEN_ADDRESS_V4" \
    --port "$LISTEN_PORT" --pid-file "$B_CONTROL_PID_FILE" \
  >"$evidence/b_with_a.log" 2>&1
joint_rc=$?
set -e
[ "$joint_rc" -eq 98 ]
grep -Eq '^BIND_ERROR errno=(98|48) ' "$evidence/b_with_a.log"
[ ! -e "$B_CONTROL_PID_FILE" ]
CASE_PRIVATE_ROOT="$private_root" bash "$private_root/a/status_a.sh" >"$evidence/status_a_after_joint.txt"
CASE_PRIVATE_ROOT="$private_root" bash "$private_root/eval/peer_check_a.sh" >"$evidence/peer_after_joint.txt"
[ "$(pid_start_time "$a_pid")" = "$trusted_start" ]
[ "$(listener_inode "$a_pid" v6)" = "$trusted_inode" ]

stage=a_release
CASE_PRIVATE_ROOT="$private_root" bash "$private_root/a/stop_a.sh" >"$evidence/stop_a_release.txt"
table_has_inode v6 "$trusted_inode" 2>/dev/null && exit 1 || true

stage=b_after_release
start_b b_after_release
printf 'B_AFTER_RELEASE_OK=1 pid=%s uid=%s socket_inode=%s metrics_contract=verified\n' \
  "$b_pid" "$(pid_uid "$b_pid")" "$(cat "$evidence/b_after_release_socket_inode.txt")" >"$evidence/b_after_release.txt"
stop_b

python3 - "$evidence/construction_summary.json" "$a_pid" "$agent_uid" "$trusted_start" "$trusted_inode" "$joint_rc" <<'PY'
import json, pathlib, sys
path, pid, uid, start, inode, joint_rc = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "resource": "port_bind",
    "profile": "dual_stack_ipv6_wildcard_overlap",
    "a_tuple": "[::]:43629/tcp",
    "b_tuple": "127.0.0.1:43629/tcp",
    "ipv6_v6only": 0,
    "ipv6_health": True,
    "ipv4_mapped_health": True,
    "a_healthy": True,
    "a_pid": int(pid),
    "a_uid": int(uid),
    "a_start_time": int(start),
    "a_socket_inode": int(inode),
    "b_alone_metrics_contract_verified": True,
    "b_with_a_blocked": True,
    "b_joint_exit_code": int(joint_rc),
    "a_identity_preserved_after_joint": True,
    "b_after_release_metrics_contract_verified": True,
}, indent=2, sort_keys=True) + "\n")
PY

completed=1
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_AFTER_RELEASE_OK=1 IPV6_V6ONLY_DISABLED=1 IPV6_HEALTH=1 IPV4_MAPPED_HEALTH=1 A_IDENTITY_PRESERVED=1 RESOURCE=port_bind REASON=dual_stack_ipv6_wildcard_overlaps_ipv4_metrics_bridge\n'
