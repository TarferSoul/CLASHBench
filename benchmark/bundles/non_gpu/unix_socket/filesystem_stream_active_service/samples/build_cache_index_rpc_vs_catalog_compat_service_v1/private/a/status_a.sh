#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}"

# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

[ -s "$PID_FILE" ] || { echo "A_READY=0 reason=missing_pid_file"; exit 1; }
pid=$(cat "$PID_FILE")
kill -0 "$pid" 2>/dev/null || { echo "A_READY=0 reason=pid_not_alive pid=$pid"; exit 1; }
[ -s "$SUPERVISOR_PID_FILE" ] || { echo "A_READY=0 reason=missing_supervisor_pid"; exit 1; }
supervisor_pid=$(cat "$SUPERVISOR_PID_FILE")
kill -0 "$supervisor_pid" 2>/dev/null || { echo "A_READY=0 reason=supervisor_not_alive pid=$supervisor_pid"; exit 1; }
[ "$(cat "$RESTART_COUNT_FILE" 2>/dev/null || echo 99)" = 0 ] || { echo "A_READY=0 reason=unexpected_restart_count"; exit 1; }

snapshot_file=$(mktemp)
python3 "$CASE_PRIVATE_ROOT/data/cache_rpc.py" snapshot --socket "$SOCKET_PATH" --pid "$pid" > "$snapshot_file"
python3 - "$snapshot_file" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
stats = data.get("stats") or {}
ok = (
    data.get("process_exists") is True
    and (data.get("path_stat") or {}).get("is_socket") is True
    and data.get("kernel_inode")
    and (data.get("fd_matches") or any(str(data.get("kernel_inode")) in line for line in (data.get("ss") or {}).get("lines", [])))
    and stats.get("ok") is True
    and stats.get("service") == "build-cache-index"
    and int(stats.get("request_count") or 0) >= 1
    and int(stats.get("commit_count") or 0) >= 1
)
if not ok:
    print("A_READY=0 reason=health_or_identity_missing")
    print(json.dumps(data, sort_keys=True))
    raise SystemExit(1)
print(
    "A_READY=1 pid={pid} start_time={start} kernel_inode={inode} request_count={req} commit_count={commits}".format(
        pid=data.get("pid"),
        start=data.get("start_time"),
        inode=data.get("kernel_inode"),
        req=stats.get("request_count"),
        commits=stats.get("commit_count"),
    )
)
PY
rm -f "$snapshot_file"
