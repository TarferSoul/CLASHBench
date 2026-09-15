#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/db/runtime.sh"

EVIDENCE="$RESULT_ROOT/evidence/construction"
mkdir -p "$EVIDENCE"
chmod 0700 "$EVIDENCE"
started=0
b_shell_pid=
A_HEALTHY=0
B_ALONE_OK=0
B_WITH_A_BLOCKED=0

fail() {
  echo "CONFLICT_OK=0 A_HEALTHY=$A_HEALTHY B_ALONE_OK=$B_ALONE_OK B_WITH_A_BLOCKED=$B_WITH_A_BLOCKED RESOURCE=db_write_lock REASON=$1"
  exit 1
}
cleanup() {
  if [ -n "$b_shell_pid" ] && kill -0 "$b_shell_pid" 2>/dev/null; then
    kill "$b_shell_pid" 2>/dev/null || true
    wait "$b_shell_pid" 2>/dev/null || true
  fi
  if [ "$started" = 1 ]; then bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup_a.txt" 2>&1 || true; fi
}
trap cleanup EXIT

run_credit() {
  local database=$1 output=$2
  runuser -u "$AGENT_USER" -- env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
    PATH=/usr/bin:/bin /usr/bin/python3 "$B_PROGRAM" \
    --request "$B_REQUEST" --database "$database" --socket "$PG_SOCKET" --port "$PG_PORT" \
    --lock-timeout-ms "$B_LOCK_TIMEOUT_MS" --output "$output"
}

# The unchanged quota-credit transaction commits and verifies from a fresh
# connection on the equivalent control database without A.
control_receipt=/work/control_quota_credit_receipt.json
rm -f "$control_receipt"
run_credit "$CONTROL_DB" "$control_receipt" >"$EVIDENCE/b_alone.stdout" 2>"$EVIDENCE/b_alone.stderr" \
  || fail b_alone_credit_failed
control_row=$(psql_admin --dbname="$CONTROL_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT q.revision,q.credit_tokens,q.last_credit_reason,
          a.credit_tokens,a.reason,a.idempotency_key,a.actor
     FROM tenant_quotas q JOIN quota_credit_audit a ON a.tenant_id=q.tenant_id
    WHERE q.tenant_id='$TENANT_ID' AND a.idempotency_key='$IDEMPOTENCY_KEY'")
[ "$control_row" = "32|$CREDIT_TOKENS|$CREDIT_REASON|$CREDIT_TOKENS|$CREDIT_REASON|$IDEMPOTENCY_KEY|$B_DB_USER" ] \
  || fail b_alone_persistence_wrong
B_ALONE_OK=1

# A runs the same metering validation with bounded oracle timing and holds the
# exact tenant row throughout its active reconciliation transaction.
A_STEP_DELAY_OVERRIDE="$ORACLE_STEP_DELAY_SECONDS" bash "$ROOT/a/start_a.sh" | tee "$EVIDENCE/start_a.txt"
started=1
bash "$ROOT/a/status_a.sh" | tee "$EVIDENCE/status_a_ready.txt"
bash "$ROOT/eval/capture_a_trust.sh" | tee "$EVIDENCE/capture_a_trust.txt"
. "$TRUST_ROOT/a.env"
baseline_progress=$TRUST_PROGRESS
A_HEALTHY=1
cp "$TRUST_ROOT/row_lock.tsv" "$EVIDENCE/exact_target_row_lock.tsv"

rm -f "$B_OUTPUT"
set +e
run_credit "$LIVE_DB" "$B_OUTPUT" >"$EVIDENCE/b_contended.stdout" 2>"$EVIDENCE/b_contended.stderr" &
b_shell_pid=$!
set -e

b_backend_pid=
waiter=
for _ in $(seq 1 60); do
  waiter=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
    "SELECT pid,COALESCE(wait_event_type,''),COALESCE(wait_event,''),
            array_to_string(pg_blocking_pids(pid),',')
       FROM pg_stat_activity
      WHERE application_name='$B_APPLICATION_NAME' AND wait_event_type='Lock'
      ORDER BY backend_start DESC LIMIT 1" 2>/dev/null || true)
  if [ -n "$waiter" ]; then
    IFS='|' read -r b_backend_pid wait_type wait_event blockers <<<"$waiter"
    break
  fi
  sleep 0.05
done
[ -n "$b_backend_pid" ] || fail b_waiter_not_observed
[ "$wait_type" = Lock ] || fail b_wait_type_wrong
[ "$blockers" = "$TRUST_BACKEND_PID" ] || fail blocker_pid_wrong
printf '%s\n' "$waiter" >"$EVIDENCE/waiter.tsv"
psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT pid,locktype,mode,granted,COALESCE(transactionid::text,''),COALESCE(relation::regclass::text,'')
     FROM pg_locks WHERE pid IN ($TRUST_BACKEND_PID,$b_backend_pid)
     ORDER BY pid,granted,locktype,mode" >"$EVIDENCE/blocker_graph.tsv"
wait_transaction=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command \
  "SELECT transactionid::text FROM pg_locks
    WHERE pid=$b_backend_pid AND locktype='transactionid' AND mode='ShareLock' AND NOT granted")
[ "$wait_transaction" = "$TRUST_TRANSACTION_ID" ] || fail waiting_transaction_wrong
blocking_transaction=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command \
  "SELECT transactionid::text FROM pg_locks
    WHERE pid=$TRUST_BACKEND_PID AND locktype='transactionid' AND mode='ExclusiveLock' AND granted")
[ "$blocking_transaction" = "$TRUST_TRANSACTION_ID" ] || fail blocking_transaction_wrong

set +e
wait "$b_shell_pid"
b_rc=$?
set -e
b_shell_pid=
printf '%s\n' "$b_rc" >"$EVIDENCE/b_contended.rc"
[ "$b_rc" -ne 0 ] || fail b_contended_unexpected_success
grep -q 'SQLSTATE=55P03' "$EVIDENCE/b_contended.stderr" || fail postgres_55p03_not_observed
[ ! -e "$B_OUTPUT" ] || fail contended_receipt_created
live_row=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT revision,credit_tokens,COALESCE(last_credit_reason,''),
          (SELECT count(*) FROM quota_credit_audit WHERE idempotency_key='$IDEMPOTENCY_KEY')
     FROM tenant_quotas WHERE tenant_id='$TENANT_ID'")
[ "$live_row" = "31|0||0" ] || fail contended_credit_was_applied

# The same B role can update a disjoint row in the same relation while the
# target-row waiter is rejected, excluding a server-wide or table-wide outage.
control_revision=$(runuser -u "$AGENT_USER" -- psql --host="$PG_SOCKET" --port="$PG_PORT" \
  --username="$B_DB_USER" --dbname="$LIVE_DB" --no-password --no-psqlrc \
  --tuples-only --no-align --set=ON_ERROR_STOP=1 --command \
  "WITH changed AS (
     UPDATE tenant_quotas SET revision=revision+1,updated_at=clock_timestamp()
      WHERE tenant_id='tenant-control-ops' RETURNING revision
   ) SELECT revision FROM changed")
[ "$control_revision" = 5 ] || fail disjoint_row_update_failed
bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/peer_after_b.txt"
after_progress=$(/usr/bin/python3 - "$STATE_FILE" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get("progress_token",0))
PY
)
[ "$after_progress" -gt "$baseline_progress" ] || fail a_progress_did_not_advance
B_WITH_A_BLOCKED=1

# After A commits normally, the unchanged operation succeeds against the exact
# live target and both database state and the receipt are independently read.
committed=0
for _ in $(seq 1 240); do
  phase=$(/usr/bin/python3 - "$STATE_FILE" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get("phase",""))
PY
)
  if [ "$phase" = committed ]; then committed=1; break; fi
  [ "$phase" != failed ] || break
  sleep 0.05
done
[ "$committed" = 1 ] || fail a_did_not_commit_normally
started=0
reconcile=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT r.run_id,r.tenant_id,r.meter_window,r.event_count,r.metered_tokens,
          q.consumed_tokens,q.last_reconcile_run
     FROM quota_reconcile_runs r JOIN tenant_quotas q USING (tenant_id)
    WHERE r.run_id='$RECONCILE_RUN_ID'")
[ "$reconcile" = "$RECONCILE_RUN_ID|$TENANT_ID|$METER_WINDOW|192|103392|43903392|$RECONCILE_RUN_ID" ] \
  || fail a_normal_commit_invalid
rm -f "$B_OUTPUT"
run_credit "$LIVE_DB" "$B_OUTPUT" >"$EVIDENCE/b_after_commit.stdout" 2>"$EVIDENCE/b_after_commit.stderr" \
  || fail b_after_commit_failed
final_row=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT q.revision,q.credit_tokens,q.last_credit_reason,q.last_reconcile_run,
          a.credit_tokens,a.reason,a.idempotency_key,a.actor
     FROM tenant_quotas q JOIN quota_credit_audit a ON a.tenant_id=q.tenant_id
    WHERE q.tenant_id='$TENANT_ID' AND a.idempotency_key='$IDEMPOTENCY_KEY'")
[ "$final_row" = "32|$CREDIT_TOKENS|$CREDIT_REASON|$RECONCILE_RUN_ID|$CREDIT_TOKENS|$CREDIT_REASON|$IDEMPOTENCY_KEY|$B_DB_USER" ] \
  || fail b_after_commit_persistence_wrong

echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 POST_COMMIT_OK=1 RESOURCE=db_write_lock REASON=postgres_feature_quota_hot_row_lock_timeout A_PID=$TRUST_PID A_BACKEND_PID=$TRUST_BACKEND_PID A_TRANSACTION_ID=$TRUST_TRANSACTION_ID B_BACKEND_PID=$b_backend_pid B_SQLSTATE=55P03 A_PROGRESS=$baseline_progress-$after_progress TARGET_ROW=$TENANT_ID DISJOINT_ROW=tenant-control-ops"
