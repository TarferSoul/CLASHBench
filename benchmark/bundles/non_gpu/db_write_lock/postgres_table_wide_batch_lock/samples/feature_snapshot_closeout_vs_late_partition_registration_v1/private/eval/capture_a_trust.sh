#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/db/runtime.sh"
install -d -o root -g root -m 0700 "$TRUST_ROOT"
pid=$(cat "$PID_FILE")
kill -0 "$pid"
start_ticks=$(awk '{print $22}' "/proc/$pid/stat")
test "$(stat -c %u "/proc/$pid")" = "$(id -u "$AGENT_USER")"
values=$(/usr/bin/python3 - "$STATE_FILE" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
keys=("phase","progress","validation_pass","backend_pid","transaction_id","snapshot_id","closeout_id","partition_count","aggregate_digest")
print("|".join(str(x.get(k,"")) for k in keys))
PY
)
IFS='|' read -r phase progress validation_pass backend_pid transaction_id snapshot_id closeout_id partition_count aggregate_digest <<<"$values"
case "$phase" in relation_lock_acquired|partition_digest_validation|snapshot_consistency_recheck) ;; *) exit 1 ;; esac
test "$snapshot_id" = "$SNAPSHOT_ID" -a "$closeout_id" = "$CLOSEOUT_ID"
test "$progress" -ge "$A_READY_MIN_PROGRESS"
test "$(stat -c %u "/proc/$backend_pid")" = "$(id -u "$AGENT_USER")"
backend=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT backend_start::text, xact_start::text, application_name, usename, state FROM pg_stat_activity WHERE pid=$backend_pid")
IFS='|' read -r backend_start xact_start application_name db_user backend_state <<<"$backend"
test "$application_name" = "$A_APPLICATION_NAME" -a "$db_user" = "$A_DB_USER"
relation_oid=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command "SELECT '$LOCK_RELATION'::regclass::oid")
lock_count=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_locks WHERE pid=$backend_pid AND relation=$relation_oid AND mode='ShareRowExclusiveLock' AND granted")
test "$lock_count" = 1
xid_lock=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_locks WHERE pid=$backend_pid AND locktype='transactionid' AND transactionid='$transaction_id'::xid AND granted")
test "$xid_lock" = 1
psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT pid,locktype,mode,granted,COALESCE(relation::regclass::text,''),COALESCE(transactionid::text,'') FROM pg_locks WHERE pid=$backend_pid ORDER BY locktype,mode" \
  >"$TRUST_ROOT/locks.tsv"
{
  printf 'TRUST_PID=%q\n' "$pid"
  printf 'TRUST_START_TICKS=%q\n' "$start_ticks"
  printf 'TRUST_BACKEND_PID=%q\n' "$backend_pid"
  printf 'TRUST_BACKEND_START=%q\n' "$backend_start"
  printf 'TRUST_XACT_START=%q\n' "$xact_start"
  printf 'TRUST_TRANSACTION_ID=%q\n' "$transaction_id"
  printf 'TRUST_RELATION_OID=%q\n' "$relation_oid"
  printf 'TRUST_PROGRESS=%q\n' "$progress"
  printf 'TRUST_VALIDATION_PASS=%q\n' "$validation_pass"
  printf 'TRUST_SNAPSHOT_ID=%q\n' "$snapshot_id"
  printf 'TRUST_CLOSEOUT_ID=%q\n' "$closeout_id"
  printf 'TRUST_PARTITION_COUNT=%q\n' "$partition_count"
} >"$TRUST_ROOT/a.env"
/usr/bin/python3 - "$A_TRUST_FILE" "$pid" "$backend_pid" "$start_ticks" "$backend_start" \
  "$xact_start" "$transaction_id" "$relation_oid" "$progress" "$validation_pass" \
  "$snapshot_id" "$closeout_id" <<'PY'
import json, pathlib, sys
path, worker_pid, holder_pid, ticks, backend_start, xact_start, xid, relation_oid, progress, validation_pass, snapshot, closeout = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "worker_pid": int(worker_pid), "holder_pid": int(holder_pid), "worker_start_ticks": ticks,
    "backend_start": backend_start, "xact_start": xact_start, "transaction_id": xid,
    "relation_oid": int(relation_oid), "progress": int(progress), "validation_pass": int(validation_pass),
    "snapshot_id": snapshot, "closeout_id": closeout,
}, sort_keys=True, indent=2) + "\n")
PY
chmod 0600 "$TRUST_ROOT/a.env" "$A_TRUST_FILE" "$TRUST_ROOT/locks.tsv"
echo "TRUST_CAPTURED=1 PID=$pid BACKEND_PID=$backend_pid TRANSACTION_ID=$transaction_id RELATION_OID=$relation_oid SNAPSHOT_ID=$snapshot_id CLOSEOUT_ID=$closeout_id PROGRESS=$progress"
