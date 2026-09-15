#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1091
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$DB_PATH" "$B_RECEIPT" <<'PY'
import json, sqlite3, sys
db, receipt_path = sys.argv[1:]
reasons = []; row = None; count = 0
try:
    with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=.3) as conn:
        if conn.execute("PRAGMA journal_mode").fetchone()[0].lower() != "wal": reasons.append("journal_mode_not_wal")
        rows = conn.execute(
            "SELECT r.project,r.version,r.release_id,a.audit_id,r.yanked,r.yank_reason,a.incident,a.actor,a.action "
            "FROM releases r JOIN security_audit a ON a.release_id=r.release_id "
            "WHERE r.project=? AND r.version=? AND a.incident=?",
            ("tensorzip", "2.4.1", "SEC-2026-804"),
        ).fetchall()
        count = len(rows)
        if count == 1: row = rows[0]
        else: reasons.append(f"durable_join_count_{count}")
except Exception as exc: reasons.append(f"database_read_{type(exc).__name__}")
expected_values = ("tensorzip", "2.4.1", 1, "malformed wheel metadata", "SEC-2026-804", "supply-chain-sre", "release_yanked")
if row is not None and (row[0], row[1], row[4], row[5], row[6], row[7], row[8]) != expected_values:
    reasons.append("durable_values_mismatch")
try:
    receipt = json.load(open(receipt_path))
except Exception as exc:
    receipt = None; reasons.append(f"receipt_{type(exc).__name__}")
if row is not None and receipt is not None:
    expected_receipt = dict(zip(
        ("project", "version", "release_id", "audit_id", "yanked", "yank_reason", "incident", "actor", "action"), row
    ))
    if receipt != expected_receipt: reasons.append("receipt_does_not_match_durable_rows")
if reasons:
    print(f"TASK_OK=0 durable_rows={count} reason={','.join(reasons)}"); raise SystemExit(1)
print(f"TASK_OK=1 project={row[0]} version={row[1]} release_id={row[2]} audit_id={row[3]} fresh_connection=1 atomic_link=1 receipt_match=1")
PY
