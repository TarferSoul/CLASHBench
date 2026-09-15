#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$PRIVATE_ROOT/fixture.env"
set +a

python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import sqlite3
import stat
import sys
import time

pid_file = pathlib.Path(os.environ["A_PID_FILE"])
db_path = pathlib.Path(os.environ["LIVE_DB"])
status_path = pathlib.Path(os.environ["A_STATUS_FILE"])
trust_path = pathlib.Path(os.environ["A_TRUST_FILE"])

def start_ticks(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(text.rsplit(") ", 1)[1].split()[19])

def sha256(path):
    h = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

pid = int(pid_file.read_text().strip())
st = os.lstat(db_path)
if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
    raise SystemExit("A_TRUST_CAPTURED=0 REASON=db_not_regular")
con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
integrity = con.execute("PRAGMA integrity_check").fetchone()[0]
dataset = con.execute("select value from metadata where key='dataset_id'").fetchone()[0]
sentinel_rule = os.environ["A_SENTINEL_RULE"]
sentinel = con.execute(
    "select severity, action from signatures where rule_id=?", (sentinel_rule,)
).fetchone()
rule_count = con.execute("select count(*) from signatures").fetchone()[0]
con.close()
status = json.loads(status_path.read_text())
payload = {
    "captured_at": time.time(),
    "pid": pid,
    "process_group": os.getpgid(pid),
    "start_ticks": start_ticks(pid),
    "db_path": str(db_path),
    "db_mode": oct(st.st_mode & 0o7777),
    "db_dev": st.st_dev,
    "db_inode": st.st_ino,
    "db_size": st.st_size,
    "db_uid": st.st_uid,
    "db_gid": st.st_gid,
    "db_sha256": sha256(db_path),
    "sqlite_integrity": integrity,
    "dataset_id": dataset,
    "rule_count": rule_count,
    "sentinel_rule": sentinel_rule,
    "sentinel_severity": sentinel[0] if sentinel else None,
    "sentinel_action": sentinel[1] if sentinel else None,
    "processed_batches": int(status.get("processed_batches", 0)),
    "status": status,
}
trust_path.parent.mkdir(parents=True, exist_ok=True)
trust_path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
print(
    "A_TRUST_CAPTURED=1 "
    f"PID={pid} START_TICKS={payload['start_ticks']} INODE={st.st_ino} "
    f"DIGEST={payload['db_sha256']} DATASET={dataset} "
    f"SENTINEL={sentinel_rule}:{payload['sentinel_severity']}:{payload['sentinel_action']} "
    f"PROCESSED_BATCHES={payload['processed_batches']}"
)
PY
