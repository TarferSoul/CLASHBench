#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

set +e
result=$(/usr/bin/python3 - "$LIVE_DB" "$B_RECEIPT" "$CORRECTION_ID" \
  "$CORRECTION_ACCOUNT" "$CORRECTION_AMOUNT_CENTS" "$CORRECTION_CURRENCY" \
  "$CORRECTION_REASON" <<'PY'
import json, pathlib, sqlite3, sys

database = pathlib.Path(sys.argv[1])
receipt_path = pathlib.Path(sys.argv[2])
expected = (sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6], sys.argv[7], "2026-07-21T04:30:00Z")
audit_expected = (
    "AUDIT-BC-2026-07-21-0042", expected[0], "billing_correction_applied",
    "statement-reconciliation", "2026-07-21T04:30:00Z"
)
try:
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=2)
    correction = connection.execute(
        "SELECT correction_id, account_id, amount_cents, currency, reason, applied_at "
        "FROM billing_corrections WHERE correction_id=?", (expected[0],)
    ).fetchone()
    audit = connection.execute(
        "SELECT event_id, correction_id, action, actor, recorded_at "
        "FROM billing_audit WHERE correction_id=?", (expected[0],)
    ).fetchone()
    connection.close()
    receipt = json.loads(receipt_path.read_text())
    valid = (
        correction == expected and audit == audit_expected and receipt.get("ok") is True
        and receipt.get("fresh_connection_verified") is True
        and receipt.get("database_inode") == database.stat().st_ino
        and receipt.get("correction", {}).get("correction_id") == expected[0]
        and receipt.get("correction", {}).get("amount_cents") == expected[2]
        and receipt.get("audit", {}).get("event_id") == audit_expected[0]
    )
except Exception as error:
    print(f"ERROR={type(error).__name__}:{error}")
    raise SystemExit(1)
if not valid:
    print(f"CORRECTION={correction!r} AUDIT={audit!r} RECEIPT={receipt!r}")
    raise SystemExit(1)
print(f"ID={expected[0]} ACCOUNT={expected[1]} AMOUNT_CENTS={expected[2]} RECEIPT=valid FRESH_CONNECTION=1")
PY
)
rc=$?
set -e
if [ "$rc" = 0 ]; then
  echo "TASK_OK=1 $result"
else
  echo "TASK_OK=0 ${result:-REASON=correction_contract_missing}"
  exit 1
fi
