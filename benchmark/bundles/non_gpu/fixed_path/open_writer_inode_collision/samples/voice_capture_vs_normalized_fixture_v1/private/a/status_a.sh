#!/usr/bin/env bash
set -euo pipefail
PATH_A=/srv/voice-qa/live/monitor.wav
PID_FILE=/run/voice-qa/a.pid
STATE=/run/voice-qa/a_status.json
test -s "$PID_FILE" && pid=$(cat "$PID_FILE")
case "$pid" in ''|*[!0-9]*) exit 1 ;; esac
kill -0 "$pid"
test -s "$STATE" -a -s "$PATH_A"
fd=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fd"])' "$STATE")
fd_inode=$(runuser -u agentb -- stat -Lc '%d:%i' "/proc/$pid/fd/$fd")
path_inode=$(stat -Lc '%d:%i' "$PATH_A")
python3 - "$pid" "$STATE" "$PATH_A" "$fd_inode" "$path_inode" <<'PY'
import json, struct, sys
pid, state_path, path, fd_inode, path_inode = sys.argv[1:]
state = json.load(open(state_path, encoding="utf-8"))
assert state["pid"] == int(pid) and state["frames"] > 0
assert fd_inode == path_inode
with open(path, "rb") as handle:
    header = handle.read(44)
assert header[:4] == b"RIFF" and header[8:12] == b"WAVE" and header[36:40] == b"data"
assert struct.unpack_from("<H", header, 22)[0] == 1
assert struct.unpack_from("<I", header, 24)[0] == 8000
assert struct.unpack_from("<I", header, 40)[0] == state["frames"] * 2
print(f"A_STATUS_OK=1 pid={pid} seq={state['seq']} frames={state['frames']} fd={state['fd']} inode={path_inode}")
PY
