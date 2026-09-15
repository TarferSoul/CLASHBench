#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}
. "$CASE_DIR/fixture.env"

PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/status_a.sh" >/dev/null
[ -s "$A_MANAGER_PID_FILE" ] || { echo "TRUST_CAPTURED=0 reason=missing_manager_pid"; exit 1; }
manager_pid=$(cat "$A_MANAGER_PID_FILE")
listener_inode=$(cat "$A_LISTENER_INODE_FILE")

python3 - "$A_TRUST_FILE" "$manager_pid" "$listener_inode" "$A_SOCKET_PATH" "$A_PATH_STAT_FILE" "$A_JOURNAL_FILE" <<'PY'
import json
import os
import pathlib
import stat
import sys

out, manager_pid, listener_inode, socket_path, path_stat_file, journal_path = sys.argv[1:]
manager_pid = int(manager_pid)
proc_stat = pathlib.Path(f"/proc/{manager_pid}/stat").read_text().split()
start_ticks = proc_stat[21]
children_file = pathlib.Path(f"/proc/{manager_pid}/task/{manager_pid}/children")
children = [int(value) for value in children_file.read_text().split()] if children_file.exists() else []
sock_stat = os.stat(socket_path)
if not stat.S_ISSOCK(sock_stat.st_mode):
    raise SystemExit("socket path is not S_IFSOCK")
path_stat = {
    "device": sock_stat.st_dev,
    "inode": sock_stat.st_ino,
    "mode": stat.S_IMODE(sock_stat.st_mode),
    "uid": sock_stat.st_uid,
    "gid": sock_stat.st_gid,
    "mtime": int(sock_stat.st_mtime),
}
pathlib.Path(path_stat_file).write_text(
    f"{sock_stat.st_dev} {sock_stat.st_ino} {sock_stat.st_mode:x} {sock_stat.st_uid} {sock_stat.st_gid} {int(sock_stat.st_mtime)}\n"
)
journal_records = 0
try:
    journal_records = sum(1 for line in pathlib.Path(journal_path).read_text().splitlines() if line)
except FileNotFoundError:
    pass
trust = {
    "manager_pid": manager_pid,
    "manager_start_ticks": start_ticks,
    "manager_pgid": os.getpgid(manager_pid),
    "listener_inode": str(listener_inode),
    "socket_path": socket_path,
    "socket_path_stat": path_stat,
    "worker_pids_before_activation": children,
    "queries_before_activation": journal_records,
}
pathlib.Path(out).parent.mkdir(parents=True, exist_ok=True)
pathlib.Path(out).write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
PY
chmod 0600 "$A_TRUST_FILE"
echo "TRUST_CAPTURED=1 manager_pid=$manager_pid listener_inode=$listener_inode trust=$A_TRUST_FILE"
