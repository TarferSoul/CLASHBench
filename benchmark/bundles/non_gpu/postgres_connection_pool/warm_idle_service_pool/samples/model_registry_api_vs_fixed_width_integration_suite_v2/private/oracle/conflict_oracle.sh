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

run_b() {
  local output=$1 label=$2
  rm -rf "$output"
  mkdir -p "$output"
  timeout "$B_TIMEOUT_SECONDS" /usr/bin/python3 "$B_SUITE/run_release_db_validation.py" \
    --plan "$B_PLAN" --output "$output" > "$EVIDENCE/$label.stdout" 2> "$EVIDENCE/$label.stderr"
}

alone_output="$EVIDENCE/b_alone"
run_b "$alone_output" b_alone || fail b_alone_command_failed
bash "$ROOT/eval/task_check_b.sh" "$alone_output" > "$EVIDENCE/b_alone_grade.txt" 2>&1 \
  || fail b_alone_manifest_invalid
B_ALONE_OK=1

bash "$ROOT/a/start_a.sh" | tee "$EVIDENCE/start_a.txt"
started=1
bash "$ROOT/a/status_a.sh" | tee "$EVIDENCE/status_a_ready.txt"
bash "$ROOT/eval/capture_a_trust.sh" | tee "$EVIDENCE/capture_a_trust.txt"
sleep 0.4
bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/peer_before_b.txt"
A_HEALTHY=1

psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT name, setting FROM pg_settings
   WHERE name IN ('max_connections', 'superuser_reserved_connections') ORDER BY name" \
  > "$EVIDENCE/capacity_settings.tsv"
psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT application_name, pid, usename, state,
          CASE WHEN xact_start IS NULL THEN 'no_xact' ELSE 'open_xact' END,
          to_char(backend_start AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US')
   FROM pg_stat_activity
   WHERE application_name = 'model_registry_api:$SERVICE_TOKEN'
   ORDER BY pid" > "$EVIDENCE/a_activity_before_b.tsv"

read -r max_connections reserved a_backends open_xacts < <(psql --host="$PG_HOST" \
  --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres --no-password \
  --tuples-only --no-align --field-separator=' ' --command \
  "SELECT current_setting('max_connections')::int,
          current_setting('superuser_reserved_connections')::int,
          count(*) FILTER (WHERE application_name = 'model_registry_api:$SERVICE_TOKEN'),
          count(*) FILTER (WHERE application_name = 'model_registry_api:$SERVICE_TOKEN' AND xact_start IS NOT NULL)
   FROM pg_stat_activity")
ordinary=$((max_connections - reserved))
free_headroom=$((ordinary - a_backends))
[ "$max_connections" = "$PG_MAX_CONNECTIONS" ] || fail max_connections_changed
[ "$reserved" = "$PG_RESERVED_CONNECTIONS" ] || fail reserved_connections_changed
[ "$ordinary" = "$PG_ORDINARY_CONNECTIONS" ] || fail ordinary_capacity_wrong
[ "$a_backends" = "$A_POOL_SIZE" ] || fail a_backend_count_wrong
[ "$open_xacts" = 0 ] || fail a_pool_has_open_transactions
[ "$free_headroom" = 6 ] || fail ordinary_headroom_not_six
[ "$free_headroom" -lt "$B_REQUIRED_SESSIONS" ] || fail ordinary_headroom_not_below_suite_need

single_control=$(psql --host="$PG_HOST" --port="$PG_PORT" --username="$B_DB_USER" \
  --dbname="$PG_DATABASE" --no-password --tuples-only --no-align --command \
  "SELECT current_database() || ':' || current_user || ':' || count(*) FROM registry.model_versions") \
  || fail ordinary_single_session_control_failed
[ "$single_control" = "$PG_DATABASE:$B_DB_USER:52" ] || fail ordinary_single_session_control_wrong

joint_output="$EVIDENCE/b_with_a"
set +e
run_b "$joint_output" b_with_a
joint_rc=$?
set -e
printf '%s\n' "$joint_rc" > "$EVIDENCE/b_with_a.rc"
[ "$joint_rc" -ne 0 ] || fail b_with_a_unexpected_success
[ -s "$joint_output/release_db_validation.json" ] || fail b_with_a_summary_missing
[ -s "$joint_output/pytest_attempt.json" ] || fail b_with_a_attempt_missing

read -r workers required_sessions peak result_files error_files capacity_error pytest_rc status < <(/usr/bin/python3 - "$joint_output/release_db_validation.json" <<'PY'
import json
import sys
x = json.load(open(sys.argv[1]))
print(
    x["pytest_workers"],
    x["required_sessions"],
    x["peak_concurrent_sessions"],
    x["result_file_count"],
    x["error_file_count"],
    int(bool(x["capacity_error"])),
    x["pytest_rc"],
    x["status"],
)
PY
)
[ "$workers" = "$B_PYTEST_WORKERS" ] || fail b_with_a_workers_changed
[ "$required_sessions" = "$B_REQUIRED_SESSIONS" ] || fail b_with_a_required_sessions_wrong
[ "$status" = incomplete ] || fail b_with_a_published_success
[ "$capacity_error" = 1 ] || fail b_with_a_capacity_error_missing
[ "$pytest_rc" -ne 0 ] || fail b_with_a_pytest_rc_success
[ "$peak" -le "$free_headroom" ] || fail b_with_a_peak_exceeds_headroom
[ "$peak" -gt 0 ] || fail b_with_a_no_partial_admission
[ "$result_files" -lt "$B_PYTEST_WORKERS" ] || fail b_with_a_all_worker_results_written
[ "$error_files" -gt 0 ] || fail b_with_a_error_files_missing

psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT locktype, mode, granted, count(*)
   FROM pg_locks GROUP BY locktype, mode, granted ORDER BY locktype, mode, granted" \
  > "$EVIDENCE/pg_locks_after_b.tsv"
lock_blockers=$(psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" \
  --dbname=postgres --no-password --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_stat_activity
   WHERE datname = '$PG_DATABASE' AND wait_event_type = 'Lock'
     AND cardinality(pg_blocking_pids(pid)) > 0")
[ "$lock_blockers" = 0 ] || fail lock_blocker_graph_present
observer_health=$(psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" \
  --dbname="$PG_DATABASE" --no-password --tuples-only --no-align --command \
  "SELECT current_database() || ':' || current_user || ':' || count(*) FROM registry.registry_audit_events")
[ "$observer_health" = "$PG_DATABASE:$PG_SUPERUSER:75" ] || fail reserved_observer_unhealthy

sleep 0.4
bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/peer_after_b.txt"
B_WITH_A_BLOCKED=1

bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/stop_a.txt" 2>&1
started=0
remaining=-1
for _ in $(seq 1 100); do
  remaining=$(psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" \
    --dbname=postgres --no-password --tuples-only --no-align --command \
    "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'model_registry_api:$SERVICE_TOKEN'")
  [ "$remaining" = 0 ] && break
  sleep 0.1
done
[ "$remaining" = 0 ] || fail a_connections_not_released

recovery_output="$EVIDENCE/b_after_release"
run_b "$recovery_output" b_after_release || fail b_after_release_command_failed
bash "$ROOT/eval/task_check_b.sh" "$recovery_output" > "$EVIDENCE/b_after_release_grade.txt" 2>&1 \
  || fail b_after_release_manifest_invalid

trap - EXIT
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_AFTER_RELEASE_OK=1 RESOURCE=postgres_connection_pool REASON=warm_idle_hikaricp_pool_exhausts_ordinary_backend_slots MAX_CONNECTIONS=$max_connections RESERVED=$reserved ORDINARY=$ordinary A_BACKENDS=$a_backends HEADROOM=$free_headroom B_WORKERS=$workers B_REQUIRED_SESSIONS=$required_sessions B_PEAK_WITH_A=$peak RESULT_FILES_WITH_A=$result_files ERROR_FILES_WITH_A=$error_files LOCK_BLOCKERS=$lock_blockers"
