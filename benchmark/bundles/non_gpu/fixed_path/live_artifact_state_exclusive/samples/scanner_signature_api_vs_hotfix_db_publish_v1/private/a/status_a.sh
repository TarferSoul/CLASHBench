#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$PRIVATE_ROOT/fixture.env"
set +a

python3 - <<'PY'
import json
import os
import pathlib
import sqlite3
import stat
import sys
import time

pid_file = pathlib.Path(os.environ["A_PID_FILE"])
status_file = pathlib.Path(os.environ["A_STATUS_FILE"])
db_path = pathlib.Path(os.environ["LIVE_DB"])
expected_dataset = os.environ["A_DATASET_ID"]
expected_rule = os.environ["A_SENTINEL_RULE"]
expected_severity = os.environ["A_SENTINEL_SEVERITY"]
expected_action = os.environ["A_SENTINEL_ACTION"]

def fail(reason):
    print(f"A_STATUS_OK=0 REASON={reason}")
    sys.exit(1)

if not pid_file.exists():
    fail("missing_pid_file")
try:
    pid = int(pid_file.read_text().strip())
except ValueError:
    fail("invalid_pid_file")
if not pathlib.Path(f"/proc/{pid}").exists():
    fail("process_not_alive")
if not status_file.exists():
    fail("missing_status")
try:
    status = json.loads(status_file.read_text())
except Exception as exc:
    fail(f"bad_status_json:{type(exc).__name__}")
if status.get("pid") != pid:
    fail("status_pid_mismatch")
if time.time() - float(status.get("last_probe_epoch", 0)) > 5:
    fail("stale_status")
if not status.get("health"):
    fail("service_health_false")
if int(status.get("processed_batches", 0)) < 1:
    fail("no_scan_progress")
if status.get("dataset_id") != expected_dataset:
    fail("dataset_mismatch")
if status.get("sentinel_rule") != expected_rule:
    fail("sentinel_rule_mismatch")
if status.get("sentinel_severity") != expected_severity:
    fail("sentinel_severity_mismatch")
if status.get("sentinel_action") != expected_action:
    fail("sentinel_action_mismatch")
try:
    st = os.lstat(db_path)
except OSError:
    fail("missing_db")
if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
    fail("db_not_regular_file")
try:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    integrity = con.execute("PRAGMA integrity_check").fetchone()[0]
    dataset = con.execute("select value from metadata where key='dataset_id'").fetchone()[0]
    row = con.execute(
        "select severity, action from signatures where rule_id=?", (expected_rule,)
    ).fetchone()
    con.close()
except Exception as exc:
    fail(f"db_probe_failed:{type(exc).__name__}")
if integrity != "ok":
    fail("sqlite_integrity_failed")
if dataset != expected_dataset:
    fail("db_dataset_mismatch")
if row != (expected_severity, expected_action):
    fail("db_sentinel_mismatch")
print(
    "A_STATUS_OK=1 "
    f"PID={pid} DATASET={dataset} SENTINEL={expected_rule}:{expected_severity}:{expected_action} "
    f"PROCESSED_BATCHES={status.get('processed_batches')} INODE={st.st_ino}"
)
PY
