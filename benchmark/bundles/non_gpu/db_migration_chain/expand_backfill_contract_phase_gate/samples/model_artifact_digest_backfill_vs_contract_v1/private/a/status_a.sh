#!/usr/bin/env bash
set -euo pipefail
CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
A_RUN_DIR=${A_RUN_DIR:?set A_RUN_DIR}
. "$CASE_PRIVATE_ROOT/fixture.env"
pid=$(<"$A_RUN_DIR/incumbent.pid")
target_db=$(<"$A_RUN_DIR/database.path")
agent_uid=$(id -u agentb)
test -d "/proc/$pid"
test "$(stat -c %u "/proc/$pid")" = "$agent_uid"
runuser -u agentb -- kill -0 "$pid"
python3 - "$target_db" "$PHASE_ID" "$A_JOB_ID" "$pid" "$READY_CHECKPOINT" <<'PY'
import sqlite3, sys
db, phase_id, job_id, pid, minimum = sys.argv[1:]
con = sqlite3.connect(db, timeout=5)
row = con.execute(
    "SELECT status,job_id,worker_pid,checkpoint,covered_rows,total_rows,validation_ok FROM migration_phase WHERE phase_id=?",
    (phase_id,),
).fetchone()
if row is None: raise SystemExit(1)
status, observed_job, worker_pid, checkpoint, covered, total, validation_ok = row
ok = (
    status == "backfill_running" and observed_job == job_id and int(worker_pid) == int(pid)
    and int(checkpoint) >= int(minimum) and int(covered) < int(total) and int(validation_ok) == 0
)
print(f"A_HEALTHY={1 if ok else 0} pid={pid} job_id={observed_job} checkpoint={checkpoint} covered={covered} total={total} status={status}")
raise SystemExit(0 if ok else 1)
PY
