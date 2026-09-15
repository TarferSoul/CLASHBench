#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"
python3 - "$CATALOG_DB" "$A_PID_FILE" "$A_TRUST_FILE" "$A_TENANT" "$A_ALIAS" "$A_MODEL_ID" <<'PY'
import hashlib, json, os, pathlib, sqlite3, sys
db, pid_file, trust_file, tenant, alias, model_id = sys.argv[1:]
pid = int(pathlib.Path(pid_file).read_text().strip())
starttime = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
st = os.stat(db)
con = sqlite3.connect(db, timeout=2.0); con.row_factory = sqlite3.Row
schema_rows = con.execute("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE type IN ('table','index','trigger') AND name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall()
schema_text = "\n".join("|".join("" if v is None else str(v) for v in row) for row in schema_rows)
idx = con.execute("SELECT sql FROM sqlite_master WHERE type='index' AND name='uq_models_tenant_alias'").fetchone()
row = con.execute("SELECT model_id,tenant_id,alias,model_kind,version,config_json,created_at,updated_at FROM models WHERE tenant_id=? AND alias=?", (tenant, alias)).fetchone()
assert row is not None and row["model_id"] == model_id
payload = {"pid": pid, "starttime": starttime, "pgid": os.getpgid(pid), "db_identity": f"{st.st_dev}:{st.st_ino}", "schema_digest": hashlib.sha256(schema_text.encode()).hexdigest(), "unique_index_sql": idx[0] if idx else "", "row_digest": hashlib.sha256(json.dumps(dict(row), sort_keys=True).encode()).hexdigest(), "row": dict(row), "checkpoint_count": con.execute("SELECT COUNT(*) FROM inference_runs WHERE model_id=?", (model_id,)).fetchone()[0], "max_run_id": con.execute("SELECT COALESCE(MAX(run_id),0) FROM inference_runs WHERE model_id=?", (model_id,)).fetchone()[0]}
path = pathlib.Path(trust_file); path.parent.mkdir(parents=True, exist_ok=True); path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n"); path.chmod(0o600)
print(f"A_TRUST_CAPTURED pid={pid} starttime={starttime} db_identity={payload['db_identity']} row_digest={payload['row_digest']} checkpoints={payload['checkpoint_count']}")
PY
