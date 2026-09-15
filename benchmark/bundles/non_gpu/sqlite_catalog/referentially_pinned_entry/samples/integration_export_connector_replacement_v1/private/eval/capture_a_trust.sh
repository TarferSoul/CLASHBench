#!/bin/bash
set -euo pipefail

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$CATALOG_DB" "$A_PID_FILE" "$A_TRUST_FILE" "$A_JOB_ID" "$A_CONNECTOR_ID" "$A_OUTPUT_FILE" <<'PY'
import hashlib, json, os, pathlib, sqlite3, sys
db, pid_file, trust_file, job_id, connector_id, output_file = sys.argv[1:]
pid = int(pathlib.Path(pid_file).read_text().strip())
with open(f"/proc/{pid}/stat", "r", encoding="utf-8") as handle:
    starttime = handle.read().split()[21]
try:
    cmdline = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode("utf-8", "replace").strip()
except Exception:
    cmdline = ""
pgid = os.getpgid(pid)
st = os.stat(db)
con = sqlite3.connect(db, timeout=1.0)
con.row_factory = sqlite3.Row
con.execute("PRAGMA foreign_keys=ON")
schema_rows = con.execute(
    """
    SELECT type, name, tbl_name, sql
    FROM sqlite_master
    WHERE type IN ('table', 'index', 'trigger') AND name NOT LIKE 'sqlite_%'
    ORDER BY type, name
    """
).fetchall()
schema_text = "\n".join("|".join("" if value is None else str(value) for value in row) for row in schema_rows)
schema_digest = hashlib.sha256(schema_text.encode("utf-8")).hexdigest()
fk_rows = [tuple(row) for row in con.execute("PRAGMA foreign_key_check").fetchall()]
if fk_rows:
    raise SystemExit(f"foreign_key_check not clean at trust capture: {fk_rows}")
connector = con.execute(
    """
    SELECT connector_id, connector_type, schema_digest, config_contract_version,
           immutable_generation, schema_path, created_at
    FROM connector_catalog WHERE connector_id = ?
    """,
    (connector_id,),
).fetchone()
job = con.execute(
    """
    SELECT job_id, connector_id, state, checkpoint_batch, rows_exported,
           output_path, claimed_by
    FROM export_jobs WHERE job_id = ?
    """,
    (job_id,),
).fetchone()
checkpoint = con.execute(
    """
    SELECT job_id, last_batch, rows_exported, artifact_digest
    FROM job_checkpoint WHERE job_id = ?
    """,
    (job_id,),
).fetchone()
if connector is None or job is None or checkpoint is None:
    raise SystemExit("missing connector, job, or checkpoint during trust capture")
connector_payload = dict(connector)
job_stable = {
    "job_id": job["job_id"],
    "connector_id": job["connector_id"],
    "state": job["state"],
    "output_path": job["output_path"],
    "claimed_by": job["claimed_by"],
}
connector_digest = hashlib.sha256(json.dumps(connector_payload, sort_keys=True).encode("utf-8")).hexdigest()
job_stable_digest = hashlib.sha256(json.dumps(job_stable, sort_keys=True).encode("utf-8")).hexdigest()
payload = {
    "pid": pid,
    "starttime": starttime,
    "pgid": pgid,
    "cmdline": cmdline,
    "db_identity": f"{st.st_dev}:{st.st_ino}",
    "schema_digest": schema_digest,
    "foreign_keys_enabled": con.execute("PRAGMA foreign_keys").fetchone()[0],
    "connector": connector_payload,
    "connector_digest": connector_digest,
    "job_stable": job_stable,
    "job_stable_digest": job_stable_digest,
    "checkpoint_batch": int(job["checkpoint_batch"]),
    "rows_exported": int(job["rows_exported"]),
    "checkpoint_artifact_digest": checkpoint["artifact_digest"],
    "output_file": output_file,
}
path = pathlib.Path(trust_file)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
path.chmod(0o600)
print(
    f"A_TRUST_CAPTURED pid={pid} starttime={starttime} db_identity={payload['db_identity']} "
    f"connector_digest={connector_digest} job_digest={job_stable_digest} checkpoint_batch={payload['checkpoint_batch']}"
)
PY
