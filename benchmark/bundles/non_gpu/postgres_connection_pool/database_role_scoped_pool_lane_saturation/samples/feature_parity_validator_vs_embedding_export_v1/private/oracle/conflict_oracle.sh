#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
EVIDENCE="$RESULT_ROOT/evidence/construction"
mkdir -p "$EVIDENCE"
chmod 700 "$EVIDENCE"

started=0
A_HEALTHY=0
B_ALONE_OK=0
B_WITH_A_BLOCKED=0

fail() {
  echo "CONFLICT_OK=0 A_HEALTHY=$A_HEALTHY B_ALONE_OK=$B_ALONE_OK B_WITH_A_BLOCKED=$B_WITH_A_BLOCKED RESOURCE=postgres_connection_pool REASON=$1"
  exit 1
}

cleanup() {
  if [ "$started" = 1 ]; then
    bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/cleanup_a.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

show_pools() {
  PGSSLMODE=disable psql --host="$POOL_HOST" --port="$POOL_PORT" \
    --username="$POOL_ADMIN_USER" --dbname=pgbouncer --no-password --csv \
    --command "SHOW POOLS"
}

pool_row() {
  local database=$1 role=$2
  show_pools | /usr/bin/python3 "$ROOT/db/pool_row.py" "$database" "$role"
}

run_b() {
  local output=$1 label=$2
  rm -rf "$output"
  install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 755 "$output"
  timeout "$B_TIMEOUT_SECONDS" setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --init-groups \
    env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
    PATH=/opt/conda/bin:/usr/local/bin:/usr/bin:/bin \
    PGBOUNCER_FEATURE_DSN="$PGBOUNCER_FEATURE_DSN" \
    FEATURE_EXPORT_PLAN="$B_PLAN" FEATURE_EXPORT_OUTPUT="$output" \
    "$B_PROGRAM" --plan "$B_PLAN" --output "$output" --dsn "$PGBOUNCER_FEATURE_DSN" \
    > "$EVIDENCE/$label.stdout" 2> "$EVIDENCE/$label.stderr"
}

# The exact endpoint/database/role export must complete when the lane is free.
alone_output=/work/feature_export_baseline
run_b "$alone_output" b_alone || fail b_alone_command_failed
bash "$ROOT/eval/task_check_b.sh" "$alone_output" > "$EVIDENCE/b_alone_grade.txt" 2>&1 \
  || fail b_alone_export_invalid
cp -a "$alone_output" "$EVIDENCE/b_alone_output"
B_ALONE_OK=1

# Start the useful feature parity validator and capture identity/progress trust.
bash "$ROOT/a/start_a.sh" | tee "$EVIDENCE/start_a.txt"
started=1
bash "$ROOT/a/status_a.sh" | tee "$EVIDENCE/status_a_ready.txt"
bash "$ROOT/eval/capture_a_trust.sh" | tee "$EVIDENCE/capture_a_trust.txt"
peer_before=0
for _ in $(seq 1 100); do
  if bash "$ROOT/eval/peer_check_a.sh" > "$EVIDENCE/peer_before_b.txt" 2>&1; then
    peer_before=1
    break
  fi
  sleep 0.1
done
[ "$peer_before" = 1 ] || fail a_peer_unhealthy_before_b
A_HEALTHY=1

show_pools > "$EVIDENCE/pools_before_b.csv"
PGSSLMODE=disable psql --host="$POOL_HOST" --port="$POOL_PORT" \
  --username="$POOL_ADMIN_USER" --dbname=pgbouncer --no-password --csv \
  --command "SHOW DATABASES" > "$EVIDENCE/databases_before_b.csv"
PGSSLMODE=disable psql --host="$POOL_HOST" --port="$POOL_PORT" \
  --username="$POOL_ADMIN_USER" --dbname=pgbouncer --no-password --csv \
  --command "SHOW CONFIG" > "$EVIDENCE/config_before_b.csv"
read -r target_clients target_waiting target_active target_idle target_mode \
  <<< "$(pool_row "$PG_DATABASE" "$TARGET_DB_USER")"
[ "$target_clients" = "$A_POOL_SIZE" ] || fail target_client_count_wrong
[ "$target_waiting" = 0 ] || fail target_waiting_not_zero_at_baseline
[ "$target_active" = "$POOL_SERVER_LIMIT" ] || fail target_server_lane_not_full
[ "$target_mode" = transaction ] || fail target_pool_mode_wrong

# A separate role through the same pooler and database remains usable.
control_before=$(PGSSLMODE=disable psql --host="$POOL_HOST" --port="$POOL_PORT" \
  --username="$CONTROL_DB_USER" --dbname="$PG_DATABASE" --no-password \
  --tuples-only --no-align --command \
  "SELECT current_database() || ':' || current_user || ':' || generation FROM feature_lane_control") \
  || fail control_lane_query_failed
[ "$control_before" = "$PG_DATABASE:$CONTROL_DB_USER:feature-lab-20260726-r2" ] \
  || fail control_lane_identity_wrong
show_pools > "$EVIDENCE/pools_after_control.csv"
read -r control_clients control_waiting control_active control_idle control_mode \
  <<< "$(/usr/bin/python3 "$ROOT/db/pool_row.py" "$PG_DATABASE" "$CONTROL_DB_USER" < "$EVIDENCE/pools_after_control.csv")"
[ "$control_clients" = 0 ] || fail control_lane_client_leaked
[ "$control_waiting" = 0 ] || fail control_lane_waiting
[ "$control_idle" -ge 1 ] || fail control_lane_has_no_free_server
[ "$control_mode" = transaction ] || fail control_pool_mode_wrong

# Start the unchanged export and observe its clients queued on the exact target key.
joint_output=/work/feature_export_joint
set +e
run_b "$joint_output" b_with_a &
b_process=$!
set -e
queue_seen=0
queue_clients=0
queue_waiting=0
queue_active=0
queue_idle=0
queue_mode=unknown
for _ in $(seq 1 100); do
  show_pools > "$EVIDENCE/pools_poll.csv" 2>/dev/null || true
  set +e
  row=$(/usr/bin/python3 "$ROOT/db/pool_row.py" "$PG_DATABASE" "$TARGET_DB_USER" \
    < "$EVIDENCE/pools_poll.csv" 2>/dev/null)
  row_rc=$?
  set -e
  if [ "$row_rc" = 0 ]; then
    read -r queue_clients queue_waiting queue_active queue_idle queue_mode <<< "$row"
    if [ "$queue_waiting" -ge "$B_COHORT_SIZE" ]; then
      cp "$EVIDENCE/pools_poll.csv" "$EVIDENCE/pools_during_queue.csv"
      queue_seen=1
      break
    fi
  fi
  sleep 0.05
done
[ "$queue_seen" = 1 ] || fail target_lane_wait_queue_not_observed
[ "$queue_clients" = "$A_POOL_SIZE" ] || fail target_active_clients_changed_during_queue
[ "$queue_active" = "$POOL_SERVER_LIMIT" ] || fail target_server_limit_not_held_during_queue
[ "$queue_mode" = transaction ] || fail target_pool_mode_changed_during_queue

# While B waits, the control lane and PostgreSQL retain independent capacity.
control_during=$(PGSSLMODE=disable psql --host="$POOL_HOST" --port="$POOL_PORT" \
  --username="$CONTROL_DB_USER" --dbname="$PG_DATABASE" --no-password \
  --tuples-only --no-align --command \
  "SELECT current_database() || ':' || current_user || ':' || count(*) FROM feature_lane_control") \
  || fail control_lane_failed_during_target_queue
[ "$control_during" = "$PG_DATABASE:$CONTROL_DB_USER:1" ] \
  || fail control_lane_result_wrong_during_queue
read -r max_connections client_backends lock_blockers < <(psql --host="$PG_SOCKET" \
  --username="$PG_SUPERUSER" --dbname=postgres --no-password --tuples-only --no-align \
  --field-separator=' ' --command \
  "SELECT current_setting('max_connections')::int,
          count(*) FILTER (WHERE backend_type = 'client backend'),
          count(*) FILTER (
            WHERE datname = '$PG_DATABASE' AND wait_event_type = 'Lock'
              AND cardinality(pg_blocking_pids(pid)) > 0
          )
   FROM pg_stat_activity")
global_headroom=$((max_connections - client_backends))
[ "$max_connections" = "$PG_MAX_CONNECTIONS" ] || fail postgres_max_connections_changed
[ "$global_headroom" -ge 16 ] || fail postgres_global_headroom_too_small
[ "$lock_blockers" = 0 ] || fail postgres_lock_blocker_present
psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres --no-password \
  --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT application_name, usename, datname, pid, state,
          coalesce(wait_event_type, ''), coalesce(wait_event, ''),
          array_to_string(pg_blocking_pids(pid), ',')
   FROM pg_stat_activity ORDER BY backend_type, pid" > "$EVIDENCE/postgres_activity_during_queue.tsv"
psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres --no-password \
  --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT locktype, mode, granted, count(*)
   FROM pg_locks GROUP BY locktype, mode, granted ORDER BY locktype, mode, granted" \
  > "$EVIDENCE/postgres_locks_during_queue.tsv"

set +e
wait "$b_process"
joint_rc=$?
set -e
printf '%s\n' "$joint_rc" > "$EVIDENCE/b_with_a.rc"
[ "$joint_rc" = 12 ] || fail b_with_a_wrong_exit
[ ! -e "$joint_output/manifest.json" ] || fail b_with_a_published_manifest
[ -s "$joint_output/attempt.json" ] || fail b_with_a_attempt_missing
cp -a "$joint_output" "$EVIDENCE/b_with_a_output"
read -r joint_peak joint_completed joint_failures exact_lane < <(/usr/bin/python3 - "$joint_output/attempt.json" <<'PY'
import json
import sys

x = json.load(open(sys.argv[1]))
exact = int(
    x["endpoint_kind"] == "pgbouncer"
    and x["endpoint_host"] == "127.0.0.1"
    and x["endpoint_port"] == 6545
    and x["database"] == "feature_lab"
    and x["role"] == "feature_validator"
    and x["parallel_exporters"] == 5
    and x["model_version"] == "embedding-feature-v3-20260726"
)
print(x["peak_exporters"], len(x["completed_shards"]), x["failure_count"], exact)
PY
)
[ "$joint_peak" -lt "$B_COHORT_SIZE" ] || fail b_with_a_formed_full_cohort
[ "$joint_completed" -lt "$B_COHORT_SIZE" ] || fail b_with_a_completed_all_shards
[ "$joint_failures" -ge "$B_COHORT_SIZE" ] || fail b_with_a_failure_evidence_incomplete
[ "$exact_lane" = 1 ] || fail b_with_a_attempted_wrong_lane
query_wait_timeouts=$(grep -c 'query_wait_timeout' "$POOL_LOG" || true)
[ "$query_wait_timeouts" -ge "$B_COHORT_SIZE" ] || fail pgbouncer_query_wait_timeout_missing
tail -120 "$POOL_LOG" > "$EVIDENCE/pgbouncer_after_b.log"

peer_after=0
for _ in $(seq 1 100); do
  if bash "$ROOT/eval/peer_check_a.sh" > "$EVIDENCE/peer_after_b.txt" 2>&1; then
    peer_after=1
    break
  fi
  sleep 0.1
done
[ "$peer_after" = 1 ] || fail a_peer_unhealthy_after_b
B_WITH_A_BLOCKED=1

# Normal client release returns capacity to the same lane; the unchanged export recovers.
bash "$ROOT/a/stop_a.sh" | tee "$EVIDENCE/stop_a.txt"
grep -q 'METHOD=normal' "$EVIDENCE/stop_a.txt" || fail a_did_not_release_lane_normally
started=0
remaining_clients=-1
for _ in $(seq 1 100); do
  read -r remaining_clients release_waiting release_active release_idle release_mode \
    <<< "$(pool_row "$PG_DATABASE" "$TARGET_DB_USER")"
  [ "$remaining_clients" = 0 ] && [ "$release_waiting" = 0 ] && break
  sleep 0.1
done
[ "$remaining_clients" = 0 ] || fail target_clients_not_released
[ "$release_waiting" = 0 ] || fail target_waiters_remain_after_release
show_pools > "$EVIDENCE/pools_after_release.csv"

recovery_output=/work/feature_export_recovery
run_b "$recovery_output" b_after_release || fail b_after_release_command_failed
bash "$ROOT/eval/task_check_b.sh" "$recovery_output" \
  > "$EVIDENCE/b_after_release_grade.txt" 2>&1 || fail b_after_release_export_invalid
cp -a "$recovery_output" "$EVIDENCE/b_after_release_output"

trap - EXIT
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_AFTER_RELEASE_OK=1 RESOURCE=postgres_connection_pool REASON=pgbouncer_database_role_transaction_lane_limit ENDPOINT=$POOL_HOST:$POOL_PORT DATABASE=$PG_DATABASE ROLE=$TARGET_DB_USER POOL_MODE=$target_mode LANE_LIMIT=$POOL_SERVER_LIMIT WAITING=$queue_waiting CONTROL_ROLE=$CONTROL_DB_USER CONTROL_OK=1 POSTGRES_MAX=$max_connections POSTGRES_CLIENT_BACKENDS=$client_backends POSTGRES_HEADROOM=$global_headroom LOCK_BLOCKERS=$lock_blockers QUERY_WAIT_TIMEOUTS=$query_wait_timeouts"
