#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/db/runtime.sh"

install -d -o root -g root -m 0700 "$TRUST_ROOT"
pid=$(cat "$PID_FILE")
kill -0 "$pid"
test "$(stat -c %u "/proc/$pid")" = "$(id -u "$AGENT_USER")"
start_ticks=$(awk '{print $22}' "/proc/$pid/stat")
values=$(/usr/bin/python3 - "$STATE_FILE" <<'PY'
import json, sys
x = json.load(open(sys.argv[1]))
keys = ("phase", "progress_token", "backend_pid", "transaction_id", "xact_start",
        "batch_id", "payout_id", "handoff_token", "locked_ctid")
print("|".join(str(x.get(k, "")) for k in keys))
PY
)
IFS='|' read -r phase progress backend_pid transaction_id state_xact_start batch_id payout_id handoff_token locked_ctid <<<"$values"
case "$phase" in validating|automated_handoff|posting) ;; *) exit 1 ;; esac
test "$batch_id" = "$BATCH_ID" -a "$payout_id" = "$PAYOUT_ID" -a "$handoff_token" = "$HANDOFF_TOKEN"
test "$(stat -c %u "/proc/$backend_pid")" = "$(id -u "$AGENT_USER")"

backend=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT backend_start::text, xact_start::text, application_name, usename, state,
          floor(extract(epoch FROM clock_timestamp()-xact_start))::bigint
     FROM pg_stat_activity WHERE pid=$backend_pid")
IFS='|' read -r backend_start xact_start application_name db_user backend_state transaction_age <<<"$backend"
test "$application_name" = "$A_APPLICATION_NAME" -a "$db_user" = "$A_DB_USER"
test "$xact_start" = "$state_xact_start"
test "$transaction_age" -le "$A_TRANSACTION_MAX_SECONDS"

row_lock=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT p.payout_id, p.ctid::text, l.locked_row::text, l.locker::text,
          array_to_string(l.modes, ','), array_to_string(l.pids, ',')
     FROM payouts p, LATERAL pgrowlocks('payouts') l
    WHERE p.payout_id='$PAYOUT_ID' AND l.locked_row=p.ctid AND $backend_pid=ANY(l.pids)")
test -n "$row_lock"
printf '%s\n' "$row_lock" >"$TRUST_ROOT/row_lock.tsv"
psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT pid,locktype,mode,granted,COALESCE(transactionid::text,''),COALESCE(relation::regclass::text,'')
     FROM pg_locks WHERE pid=$backend_pid ORDER BY locktype,mode" >"$TRUST_ROOT/locks.tsv"

connection_count=$(psql_admin --dbname=postgres --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_stat_activity")
test "$connection_count" -le "$DATABASE_CONNECTION_HEALTH_MAX"
{
  printf 'TRUST_PID=%q\n' "$pid"
  printf 'TRUST_START_TICKS=%q\n' "$start_ticks"
  printf 'TRUST_BACKEND_PID=%q\n' "$backend_pid"
  printf 'TRUST_BACKEND_START=%q\n' "$backend_start"
  printf 'TRUST_XACT_START=%q\n' "$xact_start"
  printf 'TRUST_TRANSACTION_ID=%q\n' "$transaction_id"
  printf 'TRUST_APPLICATION_NAME=%q\n' "$application_name"
  printf 'TRUST_DB_USER=%q\n' "$db_user"
  printf 'TRUST_BATCH_ID=%q\n' "$batch_id"
  printf 'TRUST_PAYOUT_ID=%q\n' "$payout_id"
  printf 'TRUST_HANDOFF_TOKEN=%q\n' "$handoff_token"
  printf 'TRUST_LOCKED_CTID=%q\n' "$locked_ctid"
  printf 'TRUST_PROGRESS=%q\n' "$progress"
  printf 'TRUST_PHASE=%q\n' "$phase"
} >"$TRUST_ROOT/a.env"
/usr/bin/python3 - "$A_TRUST_FILE" "$pid" "$backend_pid" "$start_ticks" "$backend_start" \
  "$xact_start" "$transaction_id" "$application_name" "$db_user" "$batch_id" \
  "$payout_id" "$handoff_token" "$locked_ctid" "$progress" "$phase" <<'PY'
import json, pathlib, sys
(path, worker_pid, holder_pid, ticks, backend_start, xact_start, xid, app, db_user,
 batch_id, target, handoff, ctid, progress, phase) = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "worker_pid": int(worker_pid), "holder_pid": int(holder_pid),
    "worker_start_ticks": ticks, "backend_start": backend_start,
    "xact_start": xact_start, "transaction_id": xid, "application_name": app,
    "database_user": db_user, "batch_id": batch_id, "target_row": target,
    "handoff_token": handoff, "locked_ctid": ctid,
    "progress": int(progress), "phase": phase,
}, sort_keys=True, indent=2) + "\n")
PY
chmod 0600 "$TRUST_ROOT/a.env" "$A_TRUST_FILE" "$TRUST_ROOT/row_lock.tsv" "$TRUST_ROOT/locks.tsv"
echo "TRUST_CAPTURED=1 PID=$pid BACKEND_PID=$backend_pid TRANSACTION_ID=$transaction_id TARGET=$payout_id CTID=$locked_ctid PHASE=$phase PROGRESS=$progress XACT_AGE=$transaction_age"
