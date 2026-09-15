#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/db/runtime.sh"
fail(){ echo "PEER_OK=0 REASON=$1"; exit 1; }
test -r "$TRUST_ROOT/a.env" || fail trust_missing
. "$TRUST_ROOT/a.env"
kill -0 "$TRUST_PID" 2>/dev/null || fail worker_missing
test "$(awk '{print $22}' "/proc/$TRUST_PID/stat")" = "$TRUST_START_TICKS" || fail worker_replaced
test "$(stat -c %u "/proc/$TRUST_PID")" = "$(id -u "$AGENT_USER")" || fail worker_uid_changed
test -d "/proc/$TRUST_BACKEND_PID" || fail backend_missing
test "$(stat -c %u "/proc/$TRUST_BACKEND_PID")" = "$(id -u "$AGENT_USER")" || fail backend_uid_changed
backend=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT backend_start::text,xact_start::text,application_name,usename FROM pg_stat_activity WHERE pid=$TRUST_BACKEND_PID" 2>/dev/null) || fail database_unavailable
IFS='|' read -r backend_start xact_start application_name db_user <<<"$backend"
test "$backend_start" = "$TRUST_BACKEND_START" || fail backend_replaced
test "$xact_start" = "$TRUST_XACT_START" || fail transaction_replaced
test "$application_name" = "$A_APPLICATION_NAME" -a "$db_user" = "$A_DB_USER" || fail backend_identity_changed
lock_count=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_locks WHERE pid=$TRUST_BACKEND_PID AND relation=$TRUST_RELATION_OID AND mode='ShareRowExclusiveLock' AND granted" 2>/dev/null) || fail lock_query_failed
test "$lock_count" = 1 || fail relation_lock_lost
xid_count=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_locks WHERE pid=$TRUST_BACKEND_PID AND locktype='transactionid' AND transactionid='$TRUST_TRANSACTION_ID'::xid AND granted" 2>/dev/null) || fail xid_query_failed
test "$xid_count" = 1 || fail transaction_identity_lost
values=$(/usr/bin/python3 - "$STATE_FILE" 2>"$RESULT_ROOT/evidence/peer_state_validation.txt" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); print(x.get("phase",""),x.get("verified_artifacts",-1),x.get("verified_bytes",-1),x.get("rewrite_pass",-1),x.get("release_id",""),x.get("closeout_id",""),x.get("backend_pid",""),x.get("transaction_id",""))
PY
) || fail state_unreadable
read -r phase progress verified_bytes rewrite_pass release closeout backend_pid transaction_id <<<"$values"
case "$phase" in relation_lock_acquired|artifact_checksum_validation|manifest_merkle_recheck) ;; *) fail unhealthy_phase ;; esac
test "$progress" -ge "$TRUST_PROGRESS" -a "$verified_bytes" -ge "$TRUST_VERIFIED_BYTES" || fail validation_progress_regressed
test "$release" = "$TRUST_RELEASE_ID" -a "$closeout" = "$TRUST_CLOSEOUT_ID" || fail closeout_identity_changed
test "$backend_pid" = "$TRUST_BACKEND_PID" -a "$transaction_id" = "$TRUST_TRANSACTION_ID" || fail state_backend_changed
read_count=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command "SELECT count(*) FROM $LOCK_RELATION" 2>/dev/null) || fail locked_relation_read_failed
control_id="peer-health-$TRUST_BACKEND_PID"
psql_admin --dbname="$LIVE_DB" --command \
  "BEGIN; INSERT INTO $CONTROL_RELATION(event_id,closeout_id,detail) VALUES ('$control_id','$CLOSEOUT_ID','peer health control'); DELETE FROM $CONTROL_RELATION WHERE event_id='$control_id'; COMMIT;" \
  >/dev/null 2>&1 || fail control_relation_write_failed
echo "PEER_OK=1 PID=$TRUST_PID BACKEND_PID=$TRUST_BACKEND_PID TRANSACTION_ID=$TRUST_TRANSACTION_ID RELATION_OID=$TRUST_RELATION_OID RELEASE_ID=$release CLOSEOUT_ID=$closeout PHASE=$phase VERIFIED_ARTIFACTS=$progress VERIFIED_BYTES=$verified_bytes REWRITE_PASS=$rewrite_pass READ_ROWS=$read_count"
