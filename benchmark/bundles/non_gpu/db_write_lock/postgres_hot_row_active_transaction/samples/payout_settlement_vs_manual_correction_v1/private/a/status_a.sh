#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/db/runtime.sh"

state="$STATE_FILE"
pid=$(cat "$PID_FILE")
kill -0 "$pid"
values=$(/usr/bin/python3 - "$state" <<'PY'
import json, sys
x = json.load(open(sys.argv[1]))
print("|".join(str(x.get(k, "")) for k in (
    "phase", "progress_token", "backend_pid", "transaction_id", "xact_start",
    "batch_id", "payout_id", "handoff_token"
)))
PY
)
IFS='|' read -r phase progress backend_pid transaction_id xact_start batch_id payout_id handoff_token <<< "$values"
case "$phase" in validating|automated_handoff|posting) ;; *) echo "A_HEALTHY=0 PHASE=$phase" >&2; exit 1 ;; esac
[ "$batch_id" = "$BATCH_ID" ]
[ "$payout_id" = "$PAYOUT_ID" ]
[ "$handoff_token" = "$HANDOFF_TOKEN" ]
[ "$progress" -ge "$A_READY_MIN_PROGRESS" ]

backend=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT pid, application_name, usename, backend_start::text, xact_start::text, state
     FROM pg_stat_activity WHERE pid=$backend_pid")
[ -n "$backend" ]
tx_lock=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_locks
    WHERE pid=$backend_pid AND locktype='transactionid' AND transactionid='$transaction_id'::xid
      AND mode='ExclusiveLock' AND granted")
[ "$tx_lock" = 1 ]
row_lock=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command \
  "SELECT count(*) FROM payouts p, LATERAL pgrowlocks('payouts') l
    WHERE p.payout_id='$PAYOUT_ID' AND l.locked_row=p.ctid AND $backend_pid=ANY(l.pids)")
[ "$row_lock" = 1 ]
echo "A_HEALTHY=1 PID=$pid BACKEND_PID=$backend_pid TRANSACTION_ID=$transaction_id PHASE=$phase PROGRESS=$progress"
