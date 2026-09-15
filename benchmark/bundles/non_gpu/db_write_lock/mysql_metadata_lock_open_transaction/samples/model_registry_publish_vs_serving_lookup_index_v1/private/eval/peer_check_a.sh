#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$TRUST_ROOT/a.env"
fail() { echo "PEER_OK=0 REASON=$1"; exit 1; }
read -r phase progress connection_id state_publication state_generation event_seq < <(/usr/bin/python3 - "$WORKER_ROOT/worker.state.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); print(x.get("phase",""),x.get("verified_count",0),x.get("connection_id",""),x.get("publication_id",""),x.get("routing_generation",""),x.get("last_event_sequence",0))
PY
)
[ "$state_publication" = "$TRUST_PUBLICATION_ID" ] || fail publication_replaced
[ "$state_generation" = "$TRUST_ROUTING_GENERATION" ] || fail generation_replaced
[ "$progress" -ge "$TRUST_PROGRESS" ] || fail progress_regressed
mysql --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password --batch --skip-column-names --execute "SELECT 1" | grep -qx 1 || fail database_unhealthy
if [ "$phase" = committed ]; then
  active=$(mysql --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password --batch --skip-column-names --execute "SELECT COUNT(*) FROM $LIVE_DB.$TARGET_TABLE WHERE publication_id='$TRUST_PUBLICATION_ID' AND routing_generation='$TRUST_ROUTING_GENERATION' AND serving_status='active' AND activated_at IS NOT NULL AND verified_at IS NOT NULL")
  [ "$active" = "$TARGET_ROW_COUNT" ] || fail committed_versions_incomplete
  events=$(mysql --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password --batch --skip-column-names --execute "SELECT COUNT(*) FROM $LIVE_DB.$EVENT_TABLE WHERE publication_id='$TRUST_PUBLICATION_ID'")
  [ "$events" -gt 0 ] || fail verification_events_missing
  echo "PEER_OK=1 PHASE=committed PID=$TRUST_PID CONNECTION_ID=$TRUST_CONNECTION_ID PUBLICATION_ID=$TRUST_PUBLICATION_ID ROUTING_GENERATION=$TRUST_ROUTING_GENERATION PROGRESS=$progress ACTIVE_VERSIONS=$active EVENTS=$events"
  exit 0
fi
[ "$phase" = verifying ] || fail phase_not_verifying
kill -0 "$TRUST_PID" 2>/dev/null || fail process_missing
[ "$(stat -c %u "/proc/$TRUST_PID")" = "$TRUST_INCUMBENT_UID" ] || fail process_uid_changed
[ "$(awk '{print $22}' "/proc/$TRUST_PID/stat")" = "$TRUST_START_TICKS" ] || fail process_replaced
[ "$connection_id" = "$TRUST_CONNECTION_ID" ] || fail connection_replaced
trx_row=$(mysql --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password --batch --skip-column-names --execute "SELECT trx_id,DATE_FORMAT(trx_started,'%Y-%m-%dT%H:%i:%s'),trx_state,TIMESTAMPDIFF(SECOND,trx_started,NOW()) FROM information_schema.innodb_trx WHERE trx_mysql_thread_id=$TRUST_CONNECTION_ID")
[ -n "$trx_row" ] || fail transaction_missing
IFS=$'\t' read -r trx_id trx_started trx_state trx_age <<< "$trx_row"
[ "$trx_id" = "$TRUST_TRX_ID" ] || fail transaction_replaced
[ "$trx_started" = "$TRUST_TRX_STARTED" ] || fail transaction_start_changed
[ "$trx_state" = RUNNING ] || fail transaction_not_running
[ "$trx_age" -le "$A_MAX_TRANSACTION_SECONDS" ] || fail transaction_too_old
granted=$(mysql --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password --batch --skip-column-names --execute "SELECT COUNT(*) FROM performance_schema.metadata_locks ml JOIN performance_schema.threads th ON th.THREAD_ID=ml.OWNER_THREAD_ID WHERE ml.OBJECT_TYPE='TABLE' AND ml.OBJECT_SCHEMA='$LIVE_DB' AND ml.OBJECT_NAME='$TARGET_TABLE' AND ml.LOCK_STATUS='GRANTED' AND th.PROCESSLIST_ID=$TRUST_CONNECTION_ID")
[ "$granted" -ge 1 ] || fail metadata_lock_missing
echo "PEER_OK=1 PHASE=verifying PID=$TRUST_PID CONNECTION_ID=$TRUST_CONNECTION_ID TRX_ID=$TRUST_TRX_ID PUBLICATION_ID=$TRUST_PUBLICATION_ID ROUTING_GENERATION=$TRUST_ROUTING_GENERATION PROGRESS=$progress EVENT_SEQUENCE=$event_seq TRX_AGE_SECONDS=$trx_age GRANTED_LOCKS=$granted"
