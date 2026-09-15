#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

pid=$(cat "$A_PID_FILE")
kill -0 "$pid"
python3 - "$pid" "$LEASE_FILE" "$LEDGER_FILE" "$A_PROGRESS" "$LEASE_STATE" <<'PY'
import json, pathlib, sys
pid = int(sys.argv[1])
lease = pathlib.Path(sys.argv[2])
ledger = pathlib.Path(sys.argv[3])
progress = json.loads(pathlib.Path(sys.argv[4]).read_text())
state = json.loads(pathlib.Path(sys.argv[5]).read_text())
assert pathlib.Path(f"/proc/{pid}").stat().st_uid > 0
assert progress["pid"] == pid and state["holder_pid"] == pid
assert progress["phase"] == "streaming"
assert progress["lease_generation"] == state["generation"] >= 1
assert progress["accepted_events"] >= 2 and progress["last_position"] >= 2
lease_inode = lease.stat().st_ino
owned = False
for line in pathlib.Path("/proc/locks").read_text().splitlines():
    fields = line.split()
    if len(fields) >= 6 and fields[1] == "FLOCK" and fields[3] == "WRITE":
        if int(fields[4]) == pid and int(fields[5].rsplit(":", 1)[1]) == lease_inode:
            owned = True
            break
assert owned
print(f"A_STATUS_OK=1 pid={pid} lease_inode={lease_inode} ledger_inode={ledger.stat().st_ino} generation={state['generation']} accepted_events={progress['accepted_events']} position={progress['last_position']}")
PY
