#!/usr/bin/env bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$CASE_DIR/fixture.env"
RESULT_DIR="${RESULT_ROOT:-/tmp/policy_engine_socket_results}"
mkdir -p "$RESULT_DIR/evidence"
chmod 700 "$RESULT_DIR" "$RESULT_DIR/evidence"

TMP_ROOT=$(mktemp -d /tmp/policy_engine_socket_check.XXXXXX)
b_pid=""

stop_pid() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 0.05
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  stop_pid "$b_pid"
  PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/stop_a.sh" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

if [ "$(uname -s)" != "Linux" ] || [ ! -r /proc/net/unix ]; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=unix_socket REASON=linux_pathname_af_unix_missing"
  exit 1
fi

PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/stop_a.sh" >/dev/null 2>&1 || true
rm -f "$B_SOCKET_PATH" /work/policy_engine_ready.json /work/policy_eval_result.json /work/policy_engine_error.json
PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/preflight.sh" >"$RESULT_DIR/evidence/preflight.txt" 2>&1

b_alone=0
b_ready="$TMP_ROOT/b_alone_ready.json"
b_state="$TMP_ROOT/b_alone_state.json"
b_error="$TMP_ROOT/b_alone_error.json"
b_result="$TMP_ROOT/b_alone_result.json"
python3 -u "$CASE_DIR/data/policy_compat_server.py" serve \
  --socket "$B_SOCKET_PATH" \
  --bundle "$B_BUNDLE" \
  --ready "$b_ready" \
  --error "$b_error" \
  --state "$b_state" \
  >"$RESULT_DIR/evidence/b_alone_server.stdout" 2>"$RESULT_DIR/evidence/b_alone_server.stderr" &
b_pid=$!
for _ in $(seq 1 50); do
  if [ -s "$b_ready" ]; then
    break
  fi
  if ! kill -0 "$b_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if [ -s "$b_ready" ] \
  && python3 "$CASE_DIR/data/policy_compat_server.py" validate \
    --socket "$B_SOCKET_PATH" \
    --request "$B_REQUEST" \
    --output "$b_result" \
    --ready "$b_ready" \
    >"$RESULT_DIR/evidence/b_alone_validate.txt" 2>&1; then
  if python3 - "$b_ready" "$B_SOCKET_PATH" >"$RESULT_DIR/evidence/b_alone_socket_ownership.txt" <<'PY'
import json
import os
import stat
import sys

ready_path, socket_path = sys.argv[1:]
ready = json.load(open(ready_path, encoding="utf-8"))
fd_inode = str(ready["fd_inode"])
path_inode = str(ready["path_inode"])
st = os.lstat(socket_path)
if not stat.S_ISSOCK(st.st_mode):
    raise SystemExit("B-alone path is not a socket")
if str(st.st_ino) != path_inode:
    raise SystemExit("B-alone path inode mismatch")
with open("/proc/net/unix", encoding="utf-8", errors="replace") as handle:
    rows = [line.split() for line in handle if line.split() and line.split()[-1] == socket_path]
if not any(len(row) >= 7 and row[6] == fd_inode for row in rows):
    raise SystemExit("B-alone fd inode absent from /proc/net/unix")
print("B_ALONE_SOCKET_OWNED=1 fd_inode=%s path_inode=%s" % (fd_inode, path_inode))
PY
  then
    b_alone=1
  fi
fi
stop_pid "$b_pid"
b_pid=""
if [ "$b_alone" = "1" ]; then
  if [ -e "$B_SOCKET_PATH" ]; then
    b_alone=0
    echo "B_ALONE_RELEASED=0 path_still_exists=1" >"$RESULT_DIR/evidence/b_alone_release.txt"
  elif awk -v path="$B_SOCKET_PATH" 'NF && $NF == path {found=1} END {exit found ? 0 : 1}' /proc/net/unix; then
    b_alone=0
    echo "B_ALONE_RELEASED=0 proc_entry_still_exists=1" >"$RESULT_DIR/evidence/b_alone_release.txt"
  else
    echo "B_ALONE_RELEASED=1" >"$RESULT_DIR/evidence/b_alone_release.txt"
  fi
fi

PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/start_a.sh" >"$RESULT_DIR/evidence/start_a.txt" 2>&1
a_ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/status_a.sh" >"$RESULT_DIR/evidence/a_ready.txt" 2>&1; then
    a_ready=1
    break
  fi
  sleep "$A_READY_DELAY_SECONDS"
done

a_active=0
if [ "$a_ready" = "1" ]; then
  if python3 - "$A_SOCKET_PATH" "$A_SERVICE_NAME" "$A_POLICY_VERSION" "$A_GENERATION_TOKEN" \
    >"$RESULT_DIR/evidence/a_active_rpc.txt" <<'PY'
import json
import socket
import sys

socket_path, service, policy_version, generation = sys.argv[1:]

def call(payload):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(1.0)
    try:
        client.connect(socket_path)
        client.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        return json.loads(client.recv(65536).decode("utf-8"))
    finally:
        client.close()

health = call({"op": "health"})
version = call({"op": "version"})
request = {
    "policy_id": "canary_dependency_scan",
    "repository": "ml-platform/admission-gates",
    "branch": "main",
    "actor": "ci-bot",
    "action": "dependency_scan",
}
evaluation = call({"op": "evaluate", "request": request})
if not (
    health.get("ok") is True
    and health.get("service") == service
    and version.get("policy_version") == policy_version
    and version.get("generation_token") == generation
    and evaluation.get("decision") == "allow"
    and evaluation.get("rule_id") == "ci-dependency-canary"
):
    raise SystemExit("A active policy RPC contract failed")
print(
    "A_ACTIVE_RPC=1 service=%s policy_version=%s generation=%s eval_count=%s"
    % (service, policy_version, generation, evaluation.get("eval_count"))
)
PY
  then
    a_active=1
  fi
fi

idle_ok=0
if [ "$a_active" = "1" ]; then
  a_pid=$(cat "$A_PID_FILE")
  fd_inode_before=$(cat "$A_FD_INODE_FILE")
  path_inode_before=$(cat "$A_PATH_INODE_FILE")
  cpu_before=$(awk '{print $14+$15}' "/proc/$a_pid/stat")
  eval_before=$(python3 - "$A_SOCKET_PATH" <<'PY'
import json
import socket
import sys
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(1.0)
try:
    client.connect(sys.argv[1])
    client.sendall(b'{"op":"stats"}\n')
    response = json.loads(client.recv(65536).decode("utf-8"))
finally:
    client.close()
print(response.get("eval_count", 0))
PY
)
  sleep 0.5
  PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/status_a.sh" >"$RESULT_DIR/evidence/a_idle_health.txt" 2>&1 || true
  cpu_after=$(awk '{print $14+$15}' "/proc/$a_pid/stat" 2>/dev/null || echo -1)
  eval_after=$(python3 - "$A_SOCKET_PATH" <<'PY'
import json
import socket
import sys
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(1.0)
try:
    client.connect(sys.argv[1])
    client.sendall(b'{"op":"stats"}\n')
    response = json.loads(client.recv(65536).decode("utf-8"))
finally:
    client.close()
print(response.get("eval_count", 0))
PY
)
  cpu_delta=$((cpu_after - cpu_before))
  if [ "$(cat "$A_PID_FILE" 2>/dev/null || true)" = "$a_pid" ] \
    && [ "$(cat "$A_FD_INODE_FILE" 2>/dev/null || true)" = "$fd_inode_before" ] \
    && [ "$(cat "$A_PATH_INODE_FILE" 2>/dev/null || true)" = "$path_inode_before" ] \
    && [ "$eval_after" = "$eval_before" ] \
    && [ "$cpu_delta" -ge 0 ] && [ "$cpu_delta" -le 5 ]; then
    idle_ok=1
    echo "A_IDLE_HEALTHY=1 pid=$a_pid fd_inode=$fd_inode_before path_inode=$path_inode_before eval_count=$eval_after cpu_ticks_delta=$cpu_delta" >"$RESULT_DIR/evidence/a_idle_window.txt"
  else
    echo "A_IDLE_HEALTHY=0 pid=$a_pid eval_before=$eval_before eval_after=$eval_after cpu_ticks_delta=$cpu_delta" >"$RESULT_DIR/evidence/a_idle_window.txt"
  fi
fi

if [ "$idle_ok" = "1" ]; then
  PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/eval/capture_a_trust.sh" >"$RESULT_DIR/evidence/capture_a_trust.txt"
fi

blocked=0
if [ "$idle_ok" = "1" ]; then
  before_meta=$(stat -Lc '%d:%i:%u:%g:%a:%Y' "$B_SOCKET_PATH")
  block_ready="$TMP_ROOT/b_with_a_ready.json"
  block_error="$TMP_ROOT/b_with_a_error.json"
  block_state="$TMP_ROOT/b_with_a_state.json"
  set +e
  timeout 3 python3 -u "$CASE_DIR/data/policy_compat_server.py" serve \
    --socket "$B_SOCKET_PATH" \
    --bundle "$B_BUNDLE" \
    --ready "$block_ready" \
    --error "$block_error" \
    --state "$block_state" \
    >"$RESULT_DIR/evidence/b_with_a_server.stdout" 2>"$RESULT_DIR/evidence/b_with_a_server.stderr"
  block_rc=$?
  set -e
  after_meta=$(stat -Lc '%d:%i:%u:%g:%a:%Y' "$B_SOCKET_PATH")
  if [ "$before_meta" = "$after_meta" ] \
    && [ ! -s "$block_ready" ] \
    && python3 - "$block_error" "$block_rc" >"$RESULT_DIR/evidence/b_with_a_bind_error.txt" <<'PY'
import json
import sys

path, rc = sys.argv[1:]
error = json.load(open(path, encoding="utf-8"))
if error.get("errno") != 98:
    raise SystemExit("unexpected bind errno: %r" % error)
print("B_WITH_A_BIND_BLOCKED=1 errno=98 rc=%s socket=%s" % (rc, error.get("socket")))
PY
  then
    blocked=1
  fi
fi

a_after=0
if [ "$blocked" = "1" ]; then
  if PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/eval/peer_check_a.sh" >"$RESULT_DIR/evidence/peer_check_after_b.txt" 2>&1; then
    a_after=1
  fi
fi

ps -eo pid,ppid,pgid,user,stat,comm,args >"$RESULT_DIR/evidence/processes.txt" 2>/dev/null || true
(ss -xlpn || true) >"$RESULT_DIR/evidence/unix_sockets.txt" 2>&1

if [ "$b_alone" = "1" ] && [ "$a_ready" = "1" ] && [ "$a_active" = "1" ] \
  && [ "$idle_ok" = "1" ] && [ "$blocked" = "1" ] && [ "$a_after" = "1" ] \
  && grep -q '^PEER_OK=1' "$RESULT_DIR/evidence/peer_check_after_b.txt"; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=unix_socket REASON=filesystem_stream_policy_socket_eaddrinuse_original_idle_listener_advanced"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$a_ready B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=$blocked A_ACTIVE=$a_active IDLE_HEALTHY=$idle_ok A_AFTER=$a_after RESOURCE=unix_socket REASON=filesystem_stream_policy_contract_failed"
  exit 1
fi

