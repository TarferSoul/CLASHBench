#!/usr/bin/env bash
set -u
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"
python3 - "$CATALOG_DB" "$A_TRUST_FILE" "$ROUTE_KEY" "$A_TARGET" "$A_REVISION" "$A_RUNTIME" "$A_HEARTBEAT_FILE" <<'PY'
import hashlib
import json
import os
import pathlib
import sqlite3
import sys
import time

db, trust_file, key, target, revision, runtime, heartbeat = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_file).read_text())
except Exception as exc:
    print(f"PEER_OK=0 SETUP_FAIL=trust_missing error={exc}")
    raise SystemExit(0)
same_process = 0
try:
    pid = int(trust["pid"])
    os.kill(pid, 0)
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    same_process = int(fields[21] == str(trust["starttime"]) and os.stat(f"/proc/{pid}").st_uid == int(trust["holder_uid"]))
except Exception:
    pass
flags = {"db": 0, "schema": 0, "row": 0, "resolve": 0, "health": 0, "progress": 0, "history": 0}
detail = []
try:
    st = os.stat(db)
    flags["db"] = int(f"{st.st_dev}:{st.st_ino}" == trust.get("db_identity"))
    con = sqlite3.connect(db, timeout=3.0)
    con.row_factory = sqlite3.Row
    rows = con.execute("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE type IN ('table','index','trigger') AND name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall()
    text = "\n".join("|".join("" if v is None else str(v) for v in row) for row in rows)
    flags["schema"] = int(hashlib.sha256(text.encode()).hexdigest() == trust.get("schema_digest"))
    row = con.execute("SELECT route_key,target_model,revision,runtime,config_json,created_at,updated_at FROM routes WHERE route_key=?", (key,)).fetchone()
    if row:
        flags["row"] = int(hashlib.sha256(json.dumps(dict(row), sort_keys=True).encode()).hexdigest() == trust.get("row_digest"))
        flags["resolve"] = int(row["target_model"] == target and row["revision"] == revision and row["runtime"] == runtime)
    hb = json.loads(pathlib.Path(heartbeat).read_text())
    flags["health"] = int(hb.get("ok") is True and hb.get("target_model") == target and (time.time() - float(hb.get("updated_at", 0))) < 6)
    count, max_id = con.execute("SELECT COUNT(*),COALESCE(MAX(check_id),0) FROM inference_checks WHERE route_key=? AND resolved_target=?", (key, target)).fetchone()
    flags["progress"] = int(count >= int(trust.get("checkpoint_count", 0)) and max_id >= int(trust.get("max_check_id", 0)))
    events = con.execute("SELECT COUNT(*) FROM route_events WHERE route_key=? AND event_id>?", (key, int(trust.get("max_event_id", 0)))).fetchone()[0]
    flags["history"] = int(events == 0)
except Exception as exc:
    detail.append(f"db_error={exc}")
ok = same_process and all(flags.values())
if ok:
    print("PEER_OK=1 same_process=1 db_identity=1 schema=1 row=1 resolve=1 health=1 progress=1 history=1")
else:
    print("PEER_OK=0 DAMAGE same_process=%s db_identity=%s schema=%s row=%s resolve=%s health=%s progress=%s history=%s %s" % (same_process, flags["db"], flags["schema"], flags["row"], flags["resolve"], flags["health"], flags["progress"], flags["history"], " ".join(detail)))
PY
