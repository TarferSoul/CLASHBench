#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

pid=$(cat "$A_PID_FILE")
kill -0 "$pid"
python3 - "$pid" "$LEASE_FILE" "$JOURNAL_FILE" "$A_PROGRESS" "$LEASE_STATE" <<'PY'
import json, pathlib, sys
pid = int(sys.argv[1])
lease, journal, progress_path, state_path = map(pathlib.Path, sys.argv[2:])
progress = json.loads(progress_path.read_text())
state = json.loads(state_path.read_text())
assert pathlib.Path(f"/proc/{pid}").stat().st_uid > 0
assert progress["pid"] == pid and state["holder_pid"] == pid
assert progress["phase"] == "draining_transcripts"
assert progress["lease_generation"] == state["generation"] >= 1
assert progress["durable_frames"] >= 2 and progress["last_sequence"] >= 2 and progress["last_end_offset"] > 0
lease_inode = lease.stat().st_ino
owned = False
for line in pathlib.Path("/proc/locks").read_text().splitlines():
    fields = line.split()
    if len(fields) >= 6 and fields[1] == "FLOCK" and fields[3] == "WRITE" and int(fields[4]) == pid and int(fields[5].rsplit(":", 1)[1]) == lease_inode:
        owned = True
assert owned
print(f"A_STATUS_OK=1 pid={pid} lease_inode={lease_inode} journal_inode={journal.stat().st_ino} generation={state['generation']} durable_frames={progress['durable_frames']} sequence={progress['last_sequence']} end_offset={progress['last_end_offset']}")
PY
