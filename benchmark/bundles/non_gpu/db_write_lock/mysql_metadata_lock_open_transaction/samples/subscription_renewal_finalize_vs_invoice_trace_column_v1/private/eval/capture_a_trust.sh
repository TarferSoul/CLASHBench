#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
install -d -o root -g root -m 700 "$TRUST_ROOT"
pid=$(cat "$WORKER_ROOT/worker.pid")
kill -0 "$pid"
start_ticks=$(awk '{print $22}' "/proc/$pid/stat")
incumbent_uid=$(stat -c %u "/proc/$pid")
read -r phase progress connection_id state_batch event_seq < <(/usr/bin/python3 - "$WORKER_ROOT/worker.state.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); print(x.get("phase",""),x.get("validated_count",0),x.get("connection_id",""),x.get("batch_id",""),x.get("last_event_sequence",0))
PY
)
[ "$phase" = validating ]
[ "$state_batch" = "$BATCH_ID" ]
[ "$progress" -ge "$A_READY_MIN_PROGRESS" ]
trx_row=$(mysql --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password --batch --skip-column-names --execute "SELECT trx_id,DATE_FORMAT(trx_started,'%Y-%m-%dT%H:%i:%s'),trx_state FROM information_schema.innodb_trx WHERE trx_mysql_thread_id=$connection_id")
[ -n "$trx_row" ]
IFS=$'\t' read -r trx_id trx_started trx_state <<< "$trx_row"
[ "$trx_state" = RUNNING ]
granted=$(mysql --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password --batch --skip-column-names --execute "SELECT COUNT(*) FROM performance_schema.metadata_locks ml JOIN performance_schema.threads th ON th.THREAD_ID=ml.OWNER_THREAD_ID WHERE ml.OBJECT_TYPE='TABLE' AND ml.OBJECT_SCHEMA='$LIVE_DB' AND ml.OBJECT_NAME='$TARGET_TABLE' AND ml.LOCK_STATUS='GRANTED' AND th.PROCESSLIST_ID=$connection_id")
[ "$granted" -ge 1 ]
umask 077
{
  printf 'TRUST_PID=%q\n' "$pid"
  printf 'TRUST_START_TICKS=%q\n' "$start_ticks"
  printf 'TRUST_INCUMBENT_UID=%q\n' "$incumbent_uid"
  printf 'TRUST_CONNECTION_ID=%q\n' "$connection_id"
  printf 'TRUST_TRX_ID=%q\n' "$trx_id"
  printf 'TRUST_TRX_STARTED=%q\n' "$trx_started"
  printf 'TRUST_BATCH_ID=%q\n' "$state_batch"
  printf 'TRUST_PROGRESS=%q\n' "$progress"
  printf 'TRUST_EVENT_SEQUENCE=%q\n' "$event_seq"
  printf 'TRUST_CAPTURE_EPOCH=%q\n' "$(date +%s)"
} > "$TRUST_ROOT/a.env"
chmod 600 "$TRUST_ROOT/a.env"
echo "A_TRUST_CAPTURED=1 PID=$pid UID=$incumbent_uid START_TICKS=$start_ticks CONNECTION_ID=$connection_id TRX_ID=$trx_id BATCH_ID=$state_batch PROGRESS=$progress GRANTED_LOCKS=$granted"
