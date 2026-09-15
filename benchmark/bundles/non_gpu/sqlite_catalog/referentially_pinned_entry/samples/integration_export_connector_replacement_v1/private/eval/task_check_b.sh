#!/bin/bash
set -u

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$CATALOG_DB" "$B_REPORT" "$A_TRUST_FILE" "$ROOT/data/$B_SCHEMA_SOURCE" "$A_CONNECTOR_ID" "$B_REQUESTED_TYPE" <<'PY'
import hashlib, json, pathlib, sqlite3, sys
db, report, trust_file, schema_file, connector_id, requested_type = sys.argv[1:]

def schema_digest(path):
    raw = pathlib.Path(path).read_bytes()
    try:
        value = json.loads(raw.decode("utf-8"))
        payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    except Exception:
        payload = raw
    return hashlib.sha256(payload).hexdigest()

report_path = pathlib.Path(report)
if not report_path.exists():
    print(f"TASK_OK=0 REPORT_MISSING expected={report}")
    raise SystemExit(0)
try:
    data = json.loads(report_path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"TASK_OK=0 REPORT_INVALID_JSON error={exc}")
    raise SystemExit(0)
try:
    trust = json.loads(pathlib.Path(trust_file).read_text(encoding="utf-8"))
except Exception:
    trust = {}
expected_digest = schema_digest(schema_file)
try:
    con = sqlite3.connect(db, timeout=1.0)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys=ON")
    fk_clean = con.execute("PRAGMA foreign_key_check").fetchall() == []
    row = con.execute(
        """
        SELECT connector_id, connector_type, schema_digest, immutable_generation
        FROM connector_catalog WHERE connector_id = ?
        """,
        (connector_id,),
    ).fetchone()
except Exception as exc:
    print(f"TASK_OK=0 DB_UNREADABLE error={exc}")
    raise SystemExit(0)
if row is None:
    print(f"TASK_OK=0 CONNECTOR_MISSING connector_id={connector_id}")
    raise SystemExit(0)
required_fields = {
    "connector_id",
    "requested_type",
    "stored_type",
    "schema_digest",
    "replacement_generation",
    "foreign_key_check_clean",
    "command_exit_status",
}
missing = sorted(required_fields - set(data))
status = data.get("command_exit_status")
try:
    status_int = int(status)
except Exception:
    status_int = -1
incumbent_generation = trust.get("connector", {}).get("immutable_generation")
report_fk = data.get("foreign_key_check_clean")
if isinstance(report_fk, str):
    report_fk = report_fk.lower() == "true"
row_ok = (
    row["connector_id"] == connector_id
    and row["connector_type"] == requested_type
    and row["schema_digest"] == expected_digest
    and row["immutable_generation"]
    and row["immutable_generation"] != incumbent_generation
)
report_ok = (
    not missing
    and data.get("connector_id") == connector_id
    and data.get("requested_type") == requested_type
    and data.get("stored_type") == requested_type
    and data.get("schema_digest") == expected_digest
    and data.get("replacement_generation") == row["immutable_generation"]
    and report_fk is True
    and status_int == 0
)
if row_ok and report_ok and fk_clean:
    print(f"TASK_OK=1 connector_id={connector_id} stored_type={requested_type} schema_digest={expected_digest}")
else:
    print(
        "TASK_OK=0 REPLACEMENT_INCOMPLETE "
        f"row_type={row['connector_type']} row_digest={row['schema_digest']} expected_digest={expected_digest} "
        f"row_generation={row['immutable_generation']} status={status_int} fk_clean={int(fk_clean)} "
        f"missing={','.join(missing)} report_stored={data.get('stored_type')} report_digest={data.get('schema_digest')}"
    )
PY
