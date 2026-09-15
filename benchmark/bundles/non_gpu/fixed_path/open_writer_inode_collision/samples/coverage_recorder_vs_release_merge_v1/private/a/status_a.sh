#!/usr/bin/env bash
set -euo pipefail
PATH_A=/var/lib/ci-coverage/live/coverage.info
PID_FILE=/run/ci-coverage/a.pid
STATE=/run/ci-coverage/a_status.json
test -s "$PID_FILE" && pid=$(cat "$PID_FILE")
case "$pid" in ''|*[!0-9]*) exit 1 ;; esac
kill -0 "$pid"
test -s "$STATE" -a -s "$PATH_A"
fd=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fd"])' "$STATE")
fd_inode=$(runuser -u agentb -- stat -Lc '%d:%i' "/proc/$pid/fd/$fd")
path_inode=$(stat -Lc '%d:%i' "$PATH_A")
python3 - "$pid" "$STATE" "$PATH_A" "$fd_inode" "$path_inode" <<'PY'
import json, sys
pid, state_path, path, fd_inode, path_inode = sys.argv[1:]
state = json.load(open(state_path, encoding="utf-8"))
assert state["pid"] == int(pid) and state["cycle"] >= 2
assert fd_inode == path_inode
text = open(path, encoding="utf-8").read()
assert text.count("end_of_record") == state["cycle"]
assert "SF:src/live_regression.c" in text
print(f"A_STATUS_OK=1 pid={pid} cycle={state['cycle']} fd={state['fd']} inode={path_inode}")
PY
