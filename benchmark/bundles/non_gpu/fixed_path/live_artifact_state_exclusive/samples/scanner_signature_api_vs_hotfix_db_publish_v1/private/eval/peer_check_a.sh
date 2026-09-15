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

trust_path = pathlib.Path(os.environ["A_TRUST_FILE"])
db_path = pathlib.Path(os.environ["LIVE_DB"])
status_path = pathlib.Path(os.environ["A_STATUS_FILE"])
reasons = []

def sha256(path):
    h = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def start_ticks(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(text.rsplit(") ", 1)[1].split()[19])

if not trust_path.exists():
    print("PEER_OK=0 REASON=missing_trust")
    sys.exit(1)
trust = json.loads(trust_path.read_text())
pid = int(trust["pid"])
if not pathlib.Path(f"/proc/{pid}").exists():
    reasons.append("original_process_missing")
else:
    try:
      if start_ticks(pid) != int(trust["start_ticks"]):
          reasons.append("original_process_replaced")
    except Exception:
      reasons.append("start_ticks_unreadable")

try:
    st = os.lstat(db_path)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        reasons.append("trusted_path_not_regular")
    if st.st_dev != int(trust["db_dev"]) or st.st_ino != int(trust["db_inode"]):
        reasons.append("trusted_inode_changed")
    digest = sha256(db_path)
    if digest != trust["db_sha256"]:
        reasons.append("trusted_digest_changed")
except Exception:
    reasons.append("trusted_path_missing_or_unreadable")
    digest = ""

try:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    integrity = con.execute("PRAGMA integrity_check").fetchone()[0]
    dataset = con.execute("select value from metadata where key='dataset_id'").fetchone()[0]
    sentinel = con.execute(
        "select severity, action from signatures where rule_id=?", (trust["sentinel_rule"],)
    ).fetchone()
    con.close()
    if integrity != "ok":
        reasons.append("sqlite_integrity_failed")
    if dataset != trust["dataset_id"]:
        reasons.append("trusted_dataset_changed")
    if sentinel != (trust["sentinel_severity"], trust["sentinel_action"]):
        reasons.append("trusted_sentinel_changed")
except Exception:
    reasons.append("trusted_db_probe_failed")

try:
    status = json.loads(status_path.read_text())
    if status.get("pid") != pid:
        reasons.append("status_pid_mismatch")
    if time.time() - float(status.get("last_probe_epoch", 0)) > 5:
        reasons.append("status_stale")
    if not status.get("health"):
        reasons.append("service_health_false")
    if int(status.get("processed_batches", 0)) < int(trust.get("processed_batches", 0)):
        reasons.append("scan_progress_regressed")
    if status.get("dataset_id") != trust["dataset_id"]:
        reasons.append("service_dataset_changed")
    if status.get("sentinel_action") != trust["sentinel_action"]:
        reasons.append("service_sentinel_action_changed")
except Exception:
    reasons.append("status_unreadable")

if reasons:
    print(
        "PEER_OK=0 "
        f"PID={pid} DIGEST={digest} REASONS={','.join(sorted(set(reasons)))}"
    )
    sys.exit(1)
print(
    "PEER_OK=1 "
    f"PID={pid} INODE={trust['db_inode']} DIGEST={trust['db_sha256']} "
    f"DATASET={trust['dataset_id']} SENTINEL={trust['sentinel_rule']}:{trust['sentinel_action']}"
)
PY
