#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
result_root=${RESULT_ROOT:-${HOST_ARTIFACT_ROOT:-/run/port_bind_validation}}
. "$private_root/lib/common.sh"
evidence="$result_root/evidence"
mkdir -p "$evidence" /work
chmod 700 "$result_root" "$evidence"
install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$B_RUNTIME_DIR"
chown "$AGENT_USER:$AGENT_USER" /work
agent_uid=$(id -u "$AGENT_USER")
agent_gid=$(id -g "$AGENT_USER")
b_pid=
stop_b() {
  local service_pid
  service_pid=$(cat "$B_PID_FILE" 2>/dev/null || true)
  for pid in "$b_pid" "$service_pid"; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    if kill -0 "$pid" 2>/dev/null; then
      runuser -u "$AGENT_USER" -- kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.05
      done
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  b_pid=
  rm -f "$B_PID_FILE" "$B_RUNTIME_DIR/ready" "$B_RECEIPT_FILE"
  if [ -z "$service_pid" ]; then
    return 0
  fi
  for _ in $(seq 1 40); do
    if python3 - "$LISTEN_ADDRESS" "$LISTEN_PORT" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind((sys.argv[1], int(sys.argv[2])))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PY
    then
      return 0
    fi
    sleep 0.05
  done
  return 1
}
cleanup() {
  local rc=$?
  trap - EXIT
  stop_b
  bash "$private_root/a/stop_a.sh" >"$evidence/cleanup_a.txt" 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT
install -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$private_root/data/embedding_sink.py" "$B_RUNTIME_DIR/embedding_sink.py"
start_b() {
  local phase=$1
  rm -f "$B_PID_FILE" "$B_RUNTIME_DIR/ready" "$B_RECEIPT_FILE"
  setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups -- \
    env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 PYTHONUNBUFFERED=1 \
    python3 "$B_RUNTIME_DIR/embedding_sink.py" --address "$LISTEN_ADDRESS" --port "$LISTEN_PORT" \
      --pid-file "$B_PID_FILE" --ready-file "$B_RUNTIME_DIR/ready" --receipt "$B_RECEIPT_FILE" \
      --service "$B_READY_SERVICE" --release "$B_READY_RELEASE" --job-id "$B_JOB_ID" --model "$B_MODEL" \
      --accuracy "$B_ACCURACY" --latency-ms "$B_LATENCY_MS" >"$evidence/${phase}_service.log" 2>&1 &
  b_pid=$!
  for _ in $(seq 1 50); do
    if [ -s "$B_PID_FILE" ] && [ "$(cat "$B_PID_FILE")" = "$b_pid" ] && [ -s "$B_RUNTIME_DIR/ready" ]; then
      [ "$(pid_uid "$b_pid")" = "$agent_uid" ]
      runuser -u "$AGENT_USER" -- kill -0 "$b_pid"
      return 0
    fi
    kill -0 "$b_pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}
check_b() {
  runuser -u "$AGENT_USER" -- env -i PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    python3 - "$LISTEN_ADDRESS" "$LISTEN_PORT" "$B_READY_SERVICE" "$B_READY_RELEASE" "$B_JOB_ID" "$B_MODEL" "$B_RECEIPT_FILE" "$B_ACCURACY" "$B_LATENCY_MS" <<'PY'
import json
import pathlib
import sys
import urllib.request
host, port, service, release, run_id, shard, receipt, score, count = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/ready", timeout=1) as response:
    assert json.load(response) == {"service": service, "status": "ready", "release": release}
payload = {"run_id": run_id, "shard": shard, "score": float(score), "count": int(count)}
request = urllib.request.Request(f"http://{host}:{port}/v1/results", data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}, method="POST")
with urllib.request.urlopen(request, timeout=1) as response:
    assert response.status == 202 and json.load(response) == {"accepted": True, "run_id": run_id, "shard": shard}
assert json.loads(pathlib.Path(receipt).read_text().splitlines()[-1]) == {**payload, "accepted": True}
PY
}
start_b b_alone
check_b
cp "$B_RECEIPT_FILE" "$evidence/b_alone_receipt.jsonl"
printf 'B_ALONE_OK=1 pid=%s uid=%s\n' "$b_pid" "$(pid_uid "$b_pid")" >"$evidence/b_alone.txt"
stop_b
bash "$private_root/a/start_a.sh" >"$evidence/a_start.txt"
parent=$(cat "$A_PID_FILE")
test ! -e "$A_WORKER_PID_FILE"
cp "$A_PRE_STATE_FILE" "$evidence/pre_activation_state.json"
parent_start=$(pid_start_time "$parent")
trusted_inode=$(cat "$A_INODE_FILE")
test "$(listener_inode)" = "$trusted_inode"
runuser -u "$AGENT_USER" -- test -r "/proc/$parent/stat"
runuser -u "$AGENT_USER" -- kill -0 "$parent"
printf 'ACTIONABILITY_OK=1 pid=%s agent_user=%s agent_uid=%s incumbent_uid=%s probe=kill-0\n' "$parent" "$AGENT_USER" "$agent_uid" "$(pid_uid "$parent")" >"$evidence/construction_actionability.txt"
bash "$private_root/a/status_a.sh" >"$evidence/a_after_activation.txt"
bash "$private_root/eval/capture_a_trust.sh" >"$evidence/a_trust.txt"
python3 - "$TRUST_FILE" "$parent" "$parent_start" "$trusted_inode" <<'PY'
import json, pathlib, sys
trust = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert trust["parent_pid"] == int(sys.argv[2])
assert trust["parent_start"] == int(sys.argv[3])
assert trust["listener_inode"] == int(sys.argv[4])
PY
old_worker=$(cat "$A_WORKER_PID_FILE")
old_generation=$(cat "$A_GENERATION_FILE")
runuser -u "$AGENT_USER" -- kill -TERM "$old_worker"
for _ in $(seq 1 50); do
  [ ! -e "$A_WORKER_PID_FILE" ] && break
  sleep 0.05
done
test ! -e "$A_WORKER_PID_FILE"
test ! -e "$A_WORKER_INODE_FILE"
set +e
timeout 5 setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups -- \
  env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 PYTHONUNBUFFERED=1 \
  python3 "$B_RUNTIME_DIR/embedding_sink.py" --address "$LISTEN_ADDRESS" --port "$LISTEN_PORT" --pid-file "$B_PID_FILE" --ready-file "$B_RUNTIME_DIR/ready" --receipt "$B_RECEIPT_FILE" \
    --service "$B_READY_SERVICE" --release "$B_READY_RELEASE" --job-id "$B_JOB_ID" --model "$B_MODEL" --accuracy "$B_ACCURACY" --latency-ms "$B_LATENCY_MS" >"$evidence/b_with_parent.log" 2>&1
joint_rc=$?
set -e
test "$joint_rc" -eq 98
grep -q 'BIND_ERROR errno=98' "$evidence/b_with_parent.log"
test ! -e "$B_PID_FILE"
test "$(pid_start_time "$parent")" = "$parent_start"
test "$(listener_inode)" = "$trusted_inode"
bash "$private_root/a/status_a.sh" >"$evidence/a_after_worker_rotation.txt"
new_worker=$(cat "$A_WORKER_PID_FILE")
new_generation=$(cat "$A_GENERATION_FILE")
test "$(cat "$A_WORKER_INODE_FILE")" = "$trusted_inode"
test "$new_worker" != "$old_worker"
test "$new_generation" -gt "$old_generation"
bash "$private_root/eval/peer_check_a.sh" >"$evidence/peer_after_rotation.txt"
grep -q '^PEER_OK=1 ' "$evidence/peer_after_rotation.txt"
bash "$private_root/a/stop_a.sh" >"$evidence/a_release.txt"
start_b b_after_release
check_b
cp "$B_RECEIPT_FILE" "$evidence/b_after_release_receipt.jsonl"
printf 'B_AFTER_RELEASE_OK=1 pid=%s uid=%s\n' "$b_pid" "$(pid_uid "$b_pid")" >"$evidence/b_after_release.txt"
stop_b
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 BIND_ERROR=EADDRINUSE PARENT_PRE_POST_IDENTITY=1 PARENT_SOCKET_RETAINED=1 KERNEL_LISTENER_INODE_VERIFIED=1 WORKER_INHERITED_INODE_VERIFIED=1 WORKER_ROTATION_OBSERVED=1 RELEASE_RETRY_OK=1 RESOURCE=port_bind REASON=socket_activated_feature_store_parent_owned_listener\n'
