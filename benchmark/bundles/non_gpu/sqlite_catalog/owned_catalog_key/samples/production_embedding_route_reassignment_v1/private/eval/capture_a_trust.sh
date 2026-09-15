#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"
python3 - "$CATALOG_DB" "$A_PID_FILE" "$A_TRUST_FILE" "$ROUTE_KEY" "$A_TARGET" <<'PY'
import hashlib
import json
import os
import pathlib
import sqlite3
import sys

db, pid_file, trust_file, key, target = sys.argv[1:]
pid = int(pathlib.Path(pid_file).read_text().strip())
assert os.stat(f"/proc/{pid}").st_uid == os.stat("/proc/self").st_uid == os.getuid() or os.stat(f"/proc/{pid}").st_uid > 0
stat_fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
st = os.stat(db)
con = sqlite3.connect(db, timeout=3.0)
con.row_factory = sqlite3.Row
schema_rows = con.execute("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE type IN ('table','index','trigger') AND name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall()
schema_text = "\n".join("|".join("" if v is None else str(v) for v in row) for row in schema_rows)
row = con.execute("SELECT route_key,target_model,revision,runtime,config_json,created_at,updated_at FROM routes WHERE route_key=?", (key,)).fetchone()
assert row is not None and row["target_model"] == target
checks = con.execute("SELECT COUNT(*),COALESCE(MAX(check_id),0) FROM inference_checks WHERE route_key=? AND resolved_target=?", (key, target)).fetchone()
events = con.execute("SELECT COALESCE(MAX(event_id),0) FROM route_events WHERE route_key=?", (key,)).fetchone()[0]
payload = {
    "pid": pid,
    "starttime": stat_fields[21],
    "pgid": os.getpgid(pid),
    "holder_uid": os.stat(f"/proc/{pid}").st_uid,
    "db_identity": f"{st.st_dev}:{st.st_ino}",
    "schema_digest": hashlib.sha256(schema_text.encode()).hexdigest(),
    "row_digest": hashlib.sha256(json.dumps(dict(row), sort_keys=True).encode()).hexdigest(),
    "row": dict(row),
    "checkpoint_count": int(checks[0]),
    "max_check_id": int(checks[1]),
    "max_event_id": int(events),
}
path = pathlib.Path(trust_file)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
path.chmod(0o600)
print(f"A_TRUST_CAPTURED pid={pid} holder_uid={payload['holder_uid']} db_identity={payload['db_identity']} checkpoints={payload['checkpoint_count']} max_event_id={payload['max_event_id']}")
PY
