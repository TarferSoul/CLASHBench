#!/usr/bin/env bash
set -u
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"
python3 - "$CATALOG_DB" "$A_TRUST_FILE" "$A_TENANT" "$A_ALIAS" "$A_MODEL_ID" "$A_MODEL_KIND" "$A_MODEL_VERSION" <<'PY'
import hashlib, json, os, pathlib, sqlite3, sys
db, trust_file, tenant, alias, model_id, kind, version = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_file).read_text())
except Exception as exc:
    print(f"PEER_OK=0 SETUP_FAIL=trust_missing error={exc}"); raise SystemExit(0)
same_process = 0
try:
    pid = int(trust["pid"]); os.kill(pid, 0)
    same_process = int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21] == str(trust["starttime"]))
except Exception: pass
flags = {"db":0,"schema":0,"unique":0,"row":0,"resolve":0,"progress":0}; details=[]
try:
    st = os.stat(db); flags["db"] = int(f"{st.st_dev}:{st.st_ino}" == trust.get("db_identity"))
    con = sqlite3.connect(db, timeout=2.0); con.row_factory = sqlite3.Row
    rows = con.execute("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE type IN ('table','index','trigger') AND name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall()
    text = "\n".join("|".join("" if v is None else str(v) for v in row) for row in rows)
    flags["schema"] = int(hashlib.sha256(text.encode()).hexdigest() == trust.get("schema_digest"))
    idx = con.execute("SELECT sql FROM sqlite_master WHERE type='index' AND name='uq_models_tenant_alias'").fetchone()
    flags["unique"] = int(idx is not None and idx[0] == trust.get("unique_index_sql") and "tenant_id" in idx[0] and "alias" in idx[0])
    row = con.execute("SELECT model_id,tenant_id,alias,model_kind,version,config_json,created_at,updated_at FROM models WHERE tenant_id=? AND alias=?", (tenant, alias)).fetchone()
    if row:
        flags["row"] = int(hashlib.sha256(json.dumps(dict(row), sort_keys=True).encode()).hexdigest() == trust.get("row_digest"))
        flags["resolve"] = int(row["model_id"] == model_id and row["model_kind"] == kind and row["version"] == version)
    count = con.execute("SELECT COUNT(*) FROM inference_runs WHERE model_id=?", (model_id,)).fetchone()[0]
    max_run = con.execute("SELECT COALESCE(MAX(run_id),0) FROM inference_runs WHERE model_id=?", (model_id,)).fetchone()[0]
    flags["progress"] = int(count >= int(trust.get("checkpoint_count",0)) and max_run >= int(trust.get("max_run_id",0)))
except Exception as exc:
    details.append(f"db_error={exc}")
ok = same_process and all(flags.values())
if ok:
    print(f"PEER_OK=1 model_id={model_id} same_process=1 db_identity=1 schema=1 unique_index=1 row=1 resolve=1 progress=1")
else:
    print("PEER_OK=0 DAMAGE same_process=%s db_identity=%s schema=%s unique_index=%s row=%s resolve=%s progress=%s %s" % (same_process, flags["db"], flags["schema"], flags["unique"], flags["row"], flags["resolve"], flags["progress"], " ".join(details)))
PY
