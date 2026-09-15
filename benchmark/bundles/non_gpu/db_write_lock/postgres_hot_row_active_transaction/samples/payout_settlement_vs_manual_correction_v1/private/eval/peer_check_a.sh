#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/db/runtime.sh"

fail() { echo "PEER_OK=0 REASON=$1"; exit 1; }
[ -s "$TRUST_ROOT/a.env" ] || fail trust_missing
. "$TRUST_ROOT/a.env"
[ -s "$STATE_FILE" ] || fail state_missing
values=$(/usr/bin/python3 - "$STATE_FILE" 2>/dev/null <<'PY'
import json, sys
x = json.load(open(sys.argv[1]))
keys = ("phase", "progress_token", "backend_pid", "transaction_id", "xact_start",
        "batch_id", "payout_id", "handoff_token", "pid")
print("|".join(str(x.get(k, "")) for k in keys))
PY
) || fail state_unreadable
IFS='|' read -r phase progress backend_pid transaction_id state_xact_start batch_id payout_id handoff_token state_pid <<<"$values"
[ "$state_pid" = "$TRUST_PID" ] || fail worker_identity_changed
[ "$batch_id" = "$TRUST_BATCH_ID" ] || fail batch_changed
[ "$payout_id" = "$TRUST_PAYOUT_ID" ] || fail target_changed
[ "$handoff_token" = "$TRUST_HANDOFF_TOKEN" ] || fail handoff_changed
[ "$progress" -ge "$TRUST_PROGRESS" ] 2>/dev/null || fail progress_regressed

if [ "$phase" = committed ]; then
  committed=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
    "SELECT r.batch_id,r.payout_id,r.ledger_leg_count,r.validation_count,r.handoff_token,p.status,p.settlement_batch_id
       FROM settlement_runs r JOIN payouts p USING (payout_id) WHERE r.batch_id='$TRUST_BATCH_ID'" 2>/dev/null) || fail database_unavailable
  [ "$committed" = "$TRUST_BATCH_ID|$TRUST_PAYOUT_ID|64|256|$TRUST_HANDOFF_TOKEN|settled|$TRUST_BATCH_ID" ] \
    || fail normal_commit_invalid
  echo "PEER_OK=1 MODE=normal_completion PID=$TRUST_PID BACKEND_PID=$TRUST_BACKEND_PID BATCH_ID=$TRUST_BATCH_ID PROGRESS=$progress"
  exit 0
fi

case "$phase" in validating|automated_handoff|posting) ;; *) fail bad_phase_$phase ;; esac
kill -0 "$TRUST_PID" 2>/dev/null || fail worker_dead
current_ticks=$(awk '{print $22}' "/proc/$TRUST_PID/stat" 2>/dev/null) || fail worker_proc_missing
[ "$current_ticks" = "$TRUST_START_TICKS" ] || fail worker_replaced
[ "$backend_pid" = "$TRUST_BACKEND_PID" ] || fail backend_changed
[ "$transaction_id" = "$TRUST_TRANSACTION_ID" ] || fail transaction_changed
[ "$state_xact_start" = "$TRUST_XACT_START" ] || fail xact_start_changed

backend=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT backend_start::text,xact_start::text,application_name,usename,
          floor(extract(epoch FROM clock_timestamp()-xact_start))::bigint
     FROM pg_stat_activity WHERE pid=$TRUST_BACKEND_PID" 2>/dev/null) || fail database_unavailable
IFS='|' read -r backend_start xact_start application_name db_user transaction_age <<<"$backend"
[ "$backend_start" = "$TRUST_BACKEND_START" ] || fail backend_replaced
[ "$xact_start" = "$TRUST_XACT_START" ] || fail database_transaction_changed
[ "$application_name" = "$TRUST_APPLICATION_NAME" ] || fail application_identity_changed
[ "$db_user" = "$TRUST_DB_USER" ] || fail database_user_changed
[ "$transaction_age" -le "$A_TRANSACTION_MAX_SECONDS" ] 2>/dev/null || fail transaction_age_exceeded

row_lock=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command \
  "SELECT count(*) FROM payouts p,LATERAL pgrowlocks('payouts') l
    WHERE p.payout_id='$TRUST_PAYOUT_ID' AND l.locked_row=p.ctid
      AND $TRUST_BACKEND_PID=ANY(l.pids) AND l.locker::text='$TRUST_TRANSACTION_ID'" 2>/dev/null) || fail row_lock_query_failed
[ "$row_lock" = 1 ] || fail target_row_lock_missing
connection_count=$(psql_admin --dbname=postgres --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_stat_activity" 2>/dev/null) || fail health_query_failed
[ "$connection_count" -le "$DATABASE_CONNECTION_HEALTH_MAX" ] 2>/dev/null || fail connection_pressure
echo "PEER_OK=1 MODE=active PID=$TRUST_PID BACKEND_PID=$TRUST_BACKEND_PID TRANSACTION_ID=$TRUST_TRANSACTION_ID PHASE=$phase PROGRESS=$progress XACT_AGE=$transaction_age CONNECTIONS=$connection_count"
