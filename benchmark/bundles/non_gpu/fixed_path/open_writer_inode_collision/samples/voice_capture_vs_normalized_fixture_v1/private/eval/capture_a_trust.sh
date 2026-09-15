#!/usr/bin/env bash
set -euo pipefail
PATH_A=/srv/voice-qa/live/monitor.wav
STATE=/run/voice-qa/a_status.json
PID_FILE=/run/voice-qa/a.pid
TRUST=${TRUST_ROOT:?set TRUST_ROOT}/voice_capture_vs_normalized_fixture_v1_a.json
RESULT=${RESULT_ROOT:?set RESULT_ROOT}
pid=$(cat "$PID_FILE")
fd=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fd"])' "$STATE")
fd_inode=$(runuser -u agentb -- stat -Lc '%d:%i' "/proc/$pid/fd/$fd")
path_inode=$(stat -Lc '%d:%i' "$PATH_A")
python3 - "$pid" "$STATE" "$PATH_A" "$TRUST" "$RESULT" "$fd_inode" "$path_inode" <<'PY'
import hashlib, json, pathlib, sys
pid, state_path, path, trust_path, result_root, fd_inode, path_inode = sys.argv[1:]
state = json.load(open(state_path, encoding="utf-8"))
start = open(f"/proc/{pid}/stat", encoding="utf-8").read().split()[21]
trust = {
    "pid": int(pid), "start": start, "fd": state["fd"], "frames": state["frames"],
    "fd_inode": fd_inode,
    "path_inode": path_inode,
    "digest": hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest(),
}
pathlib.Path(trust_path).write_text(json.dumps(trust, sort_keys=True) + "\n")
pathlib.Path(result_root, "evidence", "a_trust_private.json").write_text(json.dumps(trust, indent=2) + "\n")
print(f"A_TRUST_OK=1 pid={pid} fd={state['fd']} frames={state['frames']} inode={trust['path_inode']}")
PY
