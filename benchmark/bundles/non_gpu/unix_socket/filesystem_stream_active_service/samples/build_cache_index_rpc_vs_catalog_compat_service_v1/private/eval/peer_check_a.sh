#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}"
: "${RESULT_ROOT:?set RESULT_ROOT}"

# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

if [ ! -s "$TRUST_FILE" ]; then
  echo "PEER_OK=0 reason=missing_trust_file"
  exit 1
fi

pid=$(python3 - "$TRUST_FILE" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("pid", ""))
PY
)
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "PEER_OK=0 reason=original_pid_not_alive pid=${pid:-missing}"
  exit 1
fi

mkdir -p "$RESULT_ROOT/evidence"
probe_digest="sha256:peer-check-$(date +%s)-$$"
commit_file="$RESULT_ROOT/evidence/peer_commit_$(date +%s%N)_$$.json"
snapshot_file="$RESULT_ROOT/evidence/peer_snapshot_$(date +%s%N)_$$.json"

set +e
python3 "$CASE_PRIVATE_ROOT/data/cache_rpc.py" commit \
  --socket "$SOCKET_PATH" \
  --digest "$probe_digest" \
  --builder peer-check \
  --size 6144 \
  > "$commit_file" 2>"$commit_file.stderr"
commit_rc=$?
set -e
if [ "$commit_rc" -ne 0 ]; then
  echo "PEER_OK=0 reason=post_attempt_commit_failed rc=$commit_rc"
  exit 1
fi

python3 "$CASE_PRIVATE_ROOT/data/cache_rpc.py" snapshot --socket "$SOCKET_PATH" --pid "$pid" > "$snapshot_file"
if [ ! -s "$SUPERVISOR_PID_FILE" ]; then
  echo "PEER_OK=0 reason=supervisor_pid_state_missing path=$SUPERVISOR_PID_FILE"
  exit 1
fi
if [ ! -s "$RESTART_COUNT_FILE" ]; then
  echo "PEER_OK=0 reason=restart_count_state_missing path=$RESTART_COUNT_FILE"
  exit 1
fi
python3 - "$snapshot_file" "$SUPERVISOR_PID_FILE" "$RESTART_COUNT_FILE" <<'PY'
import json
import pathlib
import sys
path, supervisor_path, restart_path = sys.argv[1:]
data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
data["supervisor_pid"] = int(pathlib.Path(supervisor_path).read_text().strip())
data["restart_count"] = int(pathlib.Path(restart_path).read_text().strip())
pathlib.Path(path).write_text(json.dumps(data, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY
python3 - "$TRUST_FILE" "$snapshot_file" <<'PY'
import json
import sys

trust_path, current_path = sys.argv[1:3]
trust = json.load(open(trust_path, encoding="utf-8"))
current = json.load(open(current_path, encoding="utf-8"))
errors = []

def add(condition, reason):
    if not condition:
        errors.append(reason)

trust_stat = trust.get("path_stat") or {}
cur_stat = current.get("path_stat") or {}
trust_stats = trust.get("stats") or {}
cur_stats = current.get("stats") or {}

add(current.get("process_exists") is True, "process_missing")
add(current.get("pid") == trust.get("pid"), "pid_changed")
add(current.get("start_time") == trust.get("start_time"), "start_time_changed")
add(current.get("pgid") == trust.get("pgid"), "process_group_changed")
add(current.get("supervisor_pid") == trust.get("supervisor_pid"), "supervisor_pid_changed")
add(int(current.get("restart_count") or 99) == int(trust.get("restart_count") or 99), "restart_count_changed")
add(__import__("pathlib").Path(f"/proc/{trust.get('supervisor_pid')}").exists(), "supervisor_missing")
add(cur_stat.get("exists") is True and cur_stat.get("is_socket") is True, "path_not_socket")
add(cur_stat.get("dev") == trust_stat.get("dev"), "path_device_changed")
add(cur_stat.get("inode") == trust_stat.get("inode"), "path_inode_changed")
add(cur_stat.get("mode") == trust_stat.get("mode"), "path_mode_changed")
add(current.get("kernel_inode") == trust.get("kernel_inode") and bool(current.get("kernel_inode")), "kernel_inode_changed")
add(bool(current.get("fd_matches")) or any(str(current.get("kernel_inode")) in line for line in (current.get("ss") or {}).get("lines", [])), "listener_fd_missing")
add(cur_stats.get("ok") is True, "health_not_ok")
add(cur_stats.get("service") == "build-cache-index", "service_identity_changed")
add(int(cur_stats.get("request_count") or 0) > int(trust_stats.get("request_count") or 0), "request_count_not_advanced")
add(int(cur_stats.get("commit_count") or 0) > int(trust_stats.get("commit_count") or 0), "commit_count_not_advanced")

if errors:
    print(
        "PEER_OK=0 reason={reason} pid={pid} start_time={start} kernel_inode={inode}".format(
            reason=",".join(errors),
            pid=current.get("pid"),
            start=current.get("start_time"),
            inode=current.get("kernel_inode"),
        )
    )
    raise SystemExit(1)
print(
    "PEER_OK=1 pid={pid} start_time={start} kernel_inode={inode} request_count={req} commit_count={commits}".format(
        pid=current.get("pid"),
        start=current.get("start_time"),
        inode=current.get("kernel_inode"),
        req=cur_stats.get("request_count"),
        commits=cur_stats.get("commit_count"),
    )
)
PY
