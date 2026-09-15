#!/usr/bin/env python3
import json
import sqlite3
import sys

db, receipt = sys.argv[1:3]
try:
    conn = sqlite3.connect(db, timeout=.25, isolation_level=None)
    conn.execute("PRAGMA busy_timeout=250")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("BEGIN IMMEDIATE")
    cur = conn.execute(
        "INSERT INTO retry_decisions(job_key,decision,reason,requested_by) VALUES (?,?,?,?)",
        ("eval-shard-042", "retry", "transient_model_timeout", "recovery-sre"),
    )
    decision_id = cur.lastrowid
    cur = conn.execute(
        "INSERT INTO retry_audit(decision_id,action,incident) VALUES (?,?,?)",
        (decision_id, "retry_approved", "INC-8042"),
    )
    audit_id = cur.lastrowid
    conn.commit()
except sqlite3.OperationalError as exc:
    try:
        conn.rollback()
    except Exception:
        pass
    if "locked" in str(exc).lower() or "busy" in str(exc).lower():
        print(f"B_COMMIT=0 SQLITE_BUSY=1 error={str(exc).replace(' ', '_')}")
        raise SystemExit(75)
    raise
finally:
    try:
        conn.close()
    except Exception:
        pass

with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=.25) as verify:
    row = verify.execute(
        "SELECT d.job_key,d.decision_id,a.audit_id,d.decision,d.reason,d.requested_by,a.action,a.incident "
        "FROM retry_decisions d JOIN retry_audit a ON a.decision_id=d.decision_id WHERE d.job_key=?",
        ("eval-shard-042",),
    ).fetchone()
expected = ("eval-shard-042", decision_id, audit_id, "retry", "transient_model_timeout", "recovery-sre", "retry_approved", "INC-8042")
if row != expected:
    raise SystemExit(f"fresh verification mismatch: {row!r}")
payload = dict(zip(
    ("job_key", "decision_id", "audit_id", "decision", "reason", "requested_by", "action", "incident"),
    row,
))
with open(receipt, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True)
    handle.write("\n")
print(f"B_COMMIT=1 decision_id={decision_id} audit_id={audit_id} fresh_verify=1")
