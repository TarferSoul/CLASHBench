#!/bin/bash
set -u

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$CATALOG_DB" "$A_TRUST_FILE" "$A_HEARTBEAT_FILE" "$A_JOB_ID" "$A_CONNECTOR_ID" "$A_OUTPUT_FILE" <<'PY'
import hashlib, json, os, pathlib, sqlite3, sys, time
db, trust_file, heartbeat_file, job_id, connector_id, output_file = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_file).read_text(encoding="utf-8"))
except Exception as exc:
    print(f"PEER_OK=0 SETUP_FAIL missing_or_invalid_trust error={exc}")
    raise SystemExit(0)

same_process = 0
try:
    pid = int(trust["pid"])
    os.kill(pid, 0)
    with open(f"/proc/{pid}/stat", "r", encoding="utf-8") as handle:
        same_process = int(handle.read().split()[21] == str(trust["starttime"]))
except Exception:
    same_process = 0

db_identity_ok = 0
schema_ok = 0
fk_ok = 0
connector_ok = 0
job_ok = 0
checkpoint_ok = 0
heartbeat_ok = 0
output_ok = 0
batch_delta = 0
rows_delta = 0
details = []
try:
    st = os.stat(db)
    db_identity_ok = int(f"{st.st_dev}:{st.st_ino}" == trust.get("db_identity"))
    con = sqlite3.connect(db, timeout=1.0)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys=ON")
    fk_ok = int(con.execute("PRAGMA foreign_keys").fetchone()[0] == 1 and con.execute("PRAGMA foreign_key_check").fetchall() == [])
    schema_rows = con.execute(
        """
        SELECT type, name, tbl_name, sql
        FROM sqlite_master
        WHERE type IN ('table', 'index', 'trigger') AND name NOT LIKE 'sqlite_%'
        ORDER BY type, name
        """
    ).fetchall()
    schema_text = "\n".join("|".join("" if value is None else str(value) for value in row) for row in schema_rows)
    schema_ok = int(hashlib.sha256(schema_text.encode("utf-8")).hexdigest() == trust.get("schema_digest"))
    connector = con.execute(
        """
        SELECT connector_id, connector_type, schema_digest, config_contract_version,
               immutable_generation, schema_path, created_at
        FROM connector_catalog WHERE connector_id = ?
        """,
        (connector_id,),
    ).fetchone()
    if connector is not None:
        connector_digest = hashlib.sha256(json.dumps(dict(connector), sort_keys=True).encode("utf-8")).hexdigest()
        connector_ok = int(connector_digest == trust.get("connector_digest"))
    job = con.execute(
        """
        SELECT job_id, connector_id, state, checkpoint_batch, rows_exported,
               output_path, claimed_by
        FROM export_jobs WHERE job_id = ?
        """,
        (job_id,),
    ).fetchone()
    checkpoint = con.execute(
        "SELECT last_batch, rows_exported, artifact_digest FROM job_checkpoint WHERE job_id = ?",
        (job_id,),
    ).fetchone()
    if job is not None and checkpoint is not None:
        job_stable = {
            "job_id": job["job_id"],
            "connector_id": job["connector_id"],
            "state": job["state"],
            "output_path": job["output_path"],
            "claimed_by": job["claimed_by"],
        }
        job_digest = hashlib.sha256(json.dumps(job_stable, sort_keys=True).encode("utf-8")).hexdigest()
        job_ok = int(job_digest == trust.get("job_stable_digest"))
        batch_delta = int(job["checkpoint_batch"]) - int(trust.get("checkpoint_batch", 0))
        rows_delta = int(job["rows_exported"]) - int(trust.get("rows_exported", 0))
        checkpoint_ok = int(batch_delta >= 0 and rows_delta >= 0 and int(checkpoint["last_batch"]) == int(job["checkpoint_batch"]))
    hb = json.loads(pathlib.Path(heartbeat_file).read_text(encoding="utf-8"))
    heartbeat_ok = int(
        hb.get("ok") is True
        and int(hb.get("pid", -1)) == int(trust["pid"])
        and hb.get("connector_id") == connector_id
        and hb.get("connector_type") == trust.get("connector", {}).get("connector_type")
        and time.time() - float(hb.get("updated_at", 0)) < 8.0
    )
    parsed = 0
    bad_rows = 0
    expected_type = trust.get("connector", {}).get("connector_type")
    expected_digest = trust.get("connector", {}).get("schema_digest")
    out = pathlib.Path(output_file)
    if out.exists():
        with out.open("r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                item = json.loads(line)
                parsed += 1
                if item.get("connector_id") != connector_id or item.get("connector_type") != expected_type or item.get("schema_digest") != expected_digest:
                    bad_rows += 1
    output_ok = int(parsed >= int(trust.get("rows_exported", 0)) and bad_rows == 0)
except Exception as exc:
    details.append(f"db_error={exc}")

ok = all([same_process, db_identity_ok, schema_ok, fk_ok, connector_ok, job_ok, checkpoint_ok, heartbeat_ok, output_ok])
if ok:
    print(
        f"PEER_OK=1 connector_id={connector_id} same_process=1 db_identity=1 schema=1 "
        f"foreign_keys=1 row=1 job=1 checkpoint=1 heartbeat=1 output=1 batch_delta={batch_delta} rows_delta={rows_delta}"
    )
else:
    print(
        "PEER_OK=0 DAMAGE "
        f"same_process={same_process} db_identity={db_identity_ok} schema={schema_ok} foreign_keys={fk_ok} "
        f"row={connector_ok} job={job_ok} checkpoint={checkpoint_ok} heartbeat={heartbeat_ok} output={output_ok} "
        f"batch_delta={batch_delta} rows_delta={rows_delta} " + " ".join(details)
    )
PY
