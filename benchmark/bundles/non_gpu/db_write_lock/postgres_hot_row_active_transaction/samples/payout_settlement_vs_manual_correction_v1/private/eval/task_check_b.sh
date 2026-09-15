#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/db/runtime.sh"
fail() { echo "TASK_OK=0 REASON=$1"; exit 1; }

[ -s "$B_OUTPUT" ] || fail receipt_missing
/usr/bin/python3 - "$B_OUTPUT" "$PAYOUT_ID" "$CORRECTION_CENTS" "$CORRECTION_REASON" "$IDEMPOTENCY_KEY" <<'PY' \
  || fail receipt_contract_invalid
import json, sys
path, payout, cents, reason, key = sys.argv[1:]
x = json.load(open(path))
expected = {
    "database": "settlement_ops", "payout_id": payout, "revision": 18,
    "correction_cents": int(cents), "reason": reason,
    "idempotency_key": key, "verified": True,
}
if x != expected:
    raise SystemExit(f"unexpected receipt: {x!r}")
PY
persisted=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT p.revision,p.correction_cents,p.last_correction_reason,
          a.delta_cents,a.reason,a.idempotency_key,a.actor
     FROM payouts p JOIN payout_audit a ON a.payout_id=p.payout_id
    WHERE p.payout_id='$PAYOUT_ID' AND a.idempotency_key='$IDEMPOTENCY_KEY'" 2>/dev/null) || fail database_unavailable
[ "$persisted" = "18|$CORRECTION_CENTS|$CORRECTION_REASON|$CORRECTION_CENTS|$CORRECTION_REASON|$IDEMPOTENCY_KEY|$B_DB_USER" ] \
  || fail persisted_contract_missing
echo "TASK_OK=1 PAYOUT_ID=$PAYOUT_ID REVISION=18 CORRECTION_CENTS=$CORRECTION_CENTS ACTOR=$B_DB_USER IDEMPOTENCY_KEY=$IDEMPOTENCY_KEY RECEIPT=$B_OUTPUT"
