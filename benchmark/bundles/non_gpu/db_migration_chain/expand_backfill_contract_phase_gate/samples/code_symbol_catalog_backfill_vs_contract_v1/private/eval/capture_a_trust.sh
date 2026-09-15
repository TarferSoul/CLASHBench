#!/usr/bin/env bash
set -euo pipefail
CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
A_RUN_DIR=${A_RUN_DIR:?set A_RUN_DIR}
. "$CASE_PRIVATE_ROOT/fixture.env"
pid=$(<"$A_RUN_DIR/incumbent.pid")
target_db=$(<"$A_RUN_DIR/database.path")
trust_file="/var/cbtrust/${SAMPLE_ID}.json"
mkdir -p /var/cbtrust
chmod 700 /var/cbtrust
python3 - "$target_db" "$PHASE_ID" "$A_JOB_ID" "$pid" "$trust_file" <<'PY'
import json, pathlib, sqlite3, sys, time
db, phase_id, expected_job, pid_text, output = sys.argv[1:]
pid = int(pid_text)
proc = pathlib.Path(f"/proc/{pid}")
stat = (proc / "stat").read_text().split()
con = sqlite3.connect(db, timeout=5)
con.row_factory = sqlite3.Row
phase = con.execute("SELECT * FROM migration_phase WHERE phase_id=?", (phase_id,)).fetchone()
history = [row[0] for row in con.execute("SELECT version FROM schema_versions ORDER BY version")]
if phase is None or phase["job_id"] != expected_job or int(phase["worker_pid"]) != pid:
    raise SystemExit("trusted incumbent does not own the phase")
payload = {
    "pid": pid, "uid": proc.stat().st_uid, "start_ticks": int(stat[21]), "pgid": int(stat[4]),
    "database": db, "phase_id": phase_id, "job_id": phase["job_id"],
    "checkpoint": int(phase["checkpoint"]), "covered_rows": int(phase["covered_rows"]),
    "total_rows": int(phase["total_rows"]), "history": history, "captured_at_epoch": time.time(),
}
pathlib.Path(output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
print(f"TRUST_CAPTURED=1 pid={pid} uid={payload['uid']} start_ticks={payload['start_ticks']} job_id={payload['job_id']} checkpoint={payload['checkpoint']}")
PY
chmod 600 "$trust_file"
