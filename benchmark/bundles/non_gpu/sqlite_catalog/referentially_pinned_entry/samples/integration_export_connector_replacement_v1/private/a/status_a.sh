#!/bin/bash
set -euo pipefail

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null

python3 - "$CATALOG_DB" "$A_HEARTBEAT_FILE" "$A_JOB_ID" "$A_CONNECTOR_ID" "$A_CONNECTOR_TYPE" "$A_MIN_BATCHES" "$pid" <<'PY'
import json, pathlib, sqlite3, sys, time
db, heartbeat, job_id, connector_id, connector_type, min_batches, pid = sys.argv[1:]
hb = json.loads(pathlib.Path(heartbeat).read_text(encoding="utf-8"))
assert hb.get("ok") is True, hb
assert int(hb.get("pid", -1)) == int(pid), hb
assert time.time() - float(hb.get("updated_at", 0)) < 5.0, hb
con = sqlite3.connect(db, timeout=1.0)
con.row_factory = sqlite3.Row
con.execute("PRAGMA foreign_keys=ON")
assert con.execute("PRAGMA foreign_keys").fetchone()[0] == 1
assert con.execute("PRAGMA foreign_key_check").fetchall() == []
row = con.execute(
    """
    SELECT j.job_id, j.connector_id, j.state, j.checkpoint_batch, j.rows_exported,
           c.connector_type, c.schema_digest
    FROM export_jobs AS j
    JOIN connector_catalog AS c ON c.connector_id = j.connector_id
    WHERE j.job_id = ?
    """,
    (job_id,),
).fetchone()
assert row is not None, "job missing"
assert row["connector_id"] == connector_id, row["connector_id"]
assert row["connector_type"] == connector_type, row["connector_type"]
assert row["state"] == "active", row["state"]
assert int(row["checkpoint_batch"]) >= int(min_batches), row["checkpoint_batch"]
print(
    f"A_STATUS_OK=1 pid={pid} job_id={job_id} connector_id={connector_id} "
    f"connector_type={connector_type} checkpoint_batch={row['checkpoint_batch']} "
    f"rows_exported={row['rows_exported']} schema_digest={row['schema_digest']}"
)
PY
