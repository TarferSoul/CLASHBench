#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1091
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$DB_PATH" "$B_RECEIPT" <<'PY'
import json, os, sqlite3, sys
db, receipt_path = sys.argv[1:]
reasons = []
row = None
count = 0
try:
    with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=.3) as conn:
        if conn.execute("PRAGMA journal_mode").fetchone()[0].lower() != "wal":
            reasons.append("journal_mode_not_wal")
        rows = conn.execute(
            "SELECT d.job_key,d.decision_id,a.audit_id,d.decision,d.reason,d.requested_by,a.action,a.incident "
            "FROM retry_decisions d JOIN retry_audit a ON a.decision_id=d.decision_id WHERE d.job_key=?",
            ("eval-shard-042",),
        ).fetchall()
        count = len(rows)
        if count == 1:
            row = rows[0]
        else:
            reasons.append(f"durable_join_count_{count}")
except Exception as exc:
    reasons.append(f"database_read_{type(exc).__name__}")
expected_values = ("eval-shard-042", "retry", "transient_model_timeout", "recovery-sre", "retry_approved", "INC-8042")
if row is not None and (row[0], row[3], row[4], row[5], row[6], row[7]) != expected_values:
    reasons.append("durable_values_mismatch")
try:
    receipt = json.load(open(receipt_path))
except Exception as exc:
    receipt = None
    reasons.append(f"receipt_{type(exc).__name__}")
if row is not None and receipt is not None:
    expected_receipt = dict(zip(
        ("job_key", "decision_id", "audit_id", "decision", "reason", "requested_by", "action", "incident"),
        row,
    ))
    if receipt != expected_receipt:
        reasons.append("receipt_does_not_match_durable_rows")
if reasons:
    print(f"TASK_OK=0 durable_rows={count} reason={','.join(reasons)}")
    raise SystemExit(1)
print(f"TASK_OK=1 job_key={row[0]} decision_id={row[1]} audit_id={row[2]} fresh_connection=1 atomic_link=1 receipt_match=1")
PY
