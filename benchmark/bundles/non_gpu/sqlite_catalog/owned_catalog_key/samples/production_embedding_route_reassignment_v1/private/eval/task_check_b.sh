#!/usr/bin/env bash
set -u
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"
python3 - "$CATALOG_DB" "$A_TRUST_FILE" "$B_REPORT" "$ROUTE_KEY" "$B_TARGET" "$B_REVISION" "$B_RUNTIME" <<'PY'
import hashlib
import json
import pathlib
import sqlite3
import sys

db, trust_file, report_file, key, target, revision, runtime = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_file).read_text())
    report = json.loads(pathlib.Path(report_file).read_text())
except Exception as exc:
    print(f"TASK_OK=0 INPUT_INVALID error={exc}")
    raise SystemExit(0)
try:
    st = pathlib.Path(db).stat()
    identity_ok = f"{st.st_dev}:{st.st_ino}" == trust.get("db_identity")
    con = sqlite3.connect(db, timeout=3.0)
    con.row_factory = sqlite3.Row
    schema_rows = con.execute("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE type IN ('table','index','trigger') AND name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall()
    schema_text = "\n".join("|".join("" if v is None else str(v) for v in row) for row in schema_rows)
    schema_ok = hashlib.sha256(schema_text.encode()).hexdigest() == trust.get("schema_digest")
    row = con.execute("SELECT route_key,target_model,revision,runtime FROM routes WHERE route_key=?", (key,)).fetchone()
    row_ok = row is not None and row["target_model"] == target and row["revision"] == revision and row["runtime"] == runtime
    events = [dict(x) for x in con.execute("SELECT operation,old_target,old_revision,old_runtime,new_target,new_revision,new_runtime,actor FROM route_events WHERE route_key=? AND event_id>? ORDER BY event_id", (key, int(trust.get("max_event_id", 0))))]
    exact_event = any(e["operation"] == "UPDATE" and e["old_target"] == trust["row"]["target_model"] and e["old_revision"] == trust["row"]["revision"] and e["old_runtime"] == trust["row"]["runtime"] and e["new_target"] == target and e["new_revision"] == revision and e["new_runtime"] == runtime and e["actor"] == "catalogctl.route.assign" for e in events)
    destructive_event = any(e["operation"] in {"DELETE", "INSERT"} for e in events)
except Exception as exc:
    print(f"TASK_OK=0 DB_EVIDENCE_INVALID error={exc}")
    raise SystemExit(0)
report_ok = (
    report.get("route_key") == key and report.get("target_model") == target and
    report.get("revision") == revision and report.get("runtime") == runtime and
    report.get("database_path") == db and report.get("action") == "route_assign"
)
ok = identity_ok and schema_ok and row_ok and exact_event and not destructive_event and report_ok
if ok:
    print(f"TASK_OK=1 route_key={key} target={target} revision={revision} database_identity=1 schema=1 audit_update=1")
else:
    print(f"TASK_OK=0 row_ok={int(row_ok)} identity_ok={int(identity_ok)} schema_ok={int(schema_ok)} exact_event={int(exact_event)} destructive_event={int(destructive_event)} report_ok={int(report_ok)}")
PY
