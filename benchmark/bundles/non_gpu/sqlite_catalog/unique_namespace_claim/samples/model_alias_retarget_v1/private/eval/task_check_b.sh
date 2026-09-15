#!/usr/bin/env bash
set -u
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"
python3 - "$CATALOG_DB" "$B_REPORT" "$B_MODEL_ID" "$B_MODEL_KIND" "$B_MODEL_VERSION" "$A_TENANT" "$A_ALIAS" <<'PY'
import json, pathlib, sqlite3, sys
db, report, model_id, kind, version, tenant, alias = sys.argv[1:]
p = pathlib.Path(report)
if not p.exists():
    print(f"TASK_OK=0 REPORT_MISSING expected={report}"); raise SystemExit(0)
try:
    data = json.loads(p.read_text())
except Exception as exc:
    print(f"TASK_OK=0 REPORT_INVALID_JSON error={exc}"); raise SystemExit(0)
try:
    con = sqlite3.connect(db, timeout=2.0); con.row_factory = sqlite3.Row
    row = con.execute("SELECT model_id,model_kind,version FROM models WHERE tenant_id=? AND alias=?", (tenant, alias)).fetchone()
except Exception as exc:
    print(f"TASK_OK=0 DB_UNREADABLE error={exc}"); raise SystemExit(0)
row_ok = row is not None and row["model_id"] == model_id and row["model_kind"] == kind and row["version"] == version
report_ok = data.get("resolved_model_id") == model_id and data.get("model_kind") == kind and data.get("version") == version and data.get("alias") == alias and data.get("tenant_id") == tenant and data.get("database_path") == db
if row_ok and report_ok:
    print(f"TASK_OK=1 model_id={model_id} alias={tenant}/{alias} report={report}")
else:
    print(f"TASK_OK=0 REGISTRATION_INCOMPLETE row_ok={int(row_ok)} report_ok={int(report_ok)}")
PY
