#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
python3 - "$CATALOG_DB" "$A_TENANT" "$A_ALIAS" "$A_MODEL_ID" "$A_MODEL_KIND" "$A_MODEL_VERSION" "$A_MIN_CHECKPOINTS" "$A_HEARTBEAT_FILE" "$pid" <<'PY'
import json, pathlib, sqlite3, sys
db, tenant, alias, model_id, kind, version, minimum, heartbeat, pid = sys.argv[1:]
con = sqlite3.connect(db, timeout=2.0)
con.row_factory = sqlite3.Row
row = con.execute("SELECT model_id, model_kind, version FROM models WHERE tenant_id=? AND alias=?", (tenant, alias)).fetchone()
assert row is not None and row["model_id"] == model_id and row["model_kind"] == kind and row["version"] == version, dict(row or {})
count = con.execute("SELECT COUNT(*) FROM inference_runs WHERE model_id=?", (model_id,)).fetchone()[0]
hb = json.loads(pathlib.Path(heartbeat).read_text(encoding="utf-8"))
assert hb.get("ok") is True and hb.get("model_id") == model_id and int(hb.get("checkpoint_count", 0)) >= int(minimum)
print(f"A_STATUS_OK=1 pid={pid} model_id={model_id} alias={tenant}/{alias} checkpoints={count}")
PY
