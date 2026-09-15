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
  timeout "$B_TIMEOUT_SECONDS" "$B_PROGRAM" --plan "$B_PLAN" --output "$output" \
    > "$EVIDENCE/$label.stdout" 2> "$EVIDENCE/$label.stderr"
}

# Prove the exact four-session audit is healthy without the replica deployment.
alone_output="$EVIDENCE/b_alone"
run_b "$alone_output" b_alone || fail b_alone_command_failed
bash "$ROOT/eval/task_check_b.sh" "$alone_output" > "$EVIDENCE/b_alone_grade.txt" 2>&1 \
  || fail b_alone_audit_invalid
B_ALONE_OK=1

# Start all four productive replicas and capture every process and backend.
bash "$ROOT/a/start_a.sh" | tee "$EVIDENCE/start_a.txt"
started=1
bash "$ROOT/a/status_a.sh" | tee "$EVIDENCE/status_a_ready.txt"
bash "$ROOT/eval/capture_a_trust.sh" | tee "$EVIDENCE/capture_a_trust.txt"
sleep 0.6
bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/peer_before_b.txt"
A_HEALTHY=1

psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres --no-password \
  --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT name, setting FROM pg_settings
   WHERE name IN ('max_connections', 'superuser_reserved_connections') ORDER BY name" \
  > "$EVIDENCE/capacity_settings.tsv"
psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres --no-password \
  --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT application_name, pid, usename, state, coalesce(wait_event_type, ''),
          coalesce(wait_event, ''),
          to_char(backend_start AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US')
   FROM pg_stat_activity
   WHERE application_name LIKE 'document-index/%'
   ORDER BY application_name" > "$EVIDENCE/a_activity_before_b.tsv"
psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname="$PG_DATABASE" \
  --no-password --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT replica, sum(commits), sum(documents_indexed), max(updated_at)
   FROM replica_progress GROUP BY replica ORDER BY replica" \
  > "$EVIDENCE/a_progress_before_b.tsv"

read -r max_connections reserved a_backends replica_groups min_pool max_pool < <(psql \
  --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres --no-password \
  --tuples-only --no-align --field-separator=' ' --command \
  "WITH grouped AS (
     SELECT split_part(application_name, '/', 2) AS replica, count(*) AS n
     FROM pg_stat_activity
     WHERE application_name LIKE 'document-index/%'
     GROUP BY 1
   )
   SELECT current_setting('max_connections')::int,
          current_setting('superuser_reserved_connections')::int,
          coalesce(sum(n), 0), count(*), coalesce(min(n), 0), coalesce(max(n), 0)
   FROM grouped")
ordinary=$((max_connections - reserved))
headroom=$((ordinary - a_backends))
one_replica_release_headroom=$((headroom + max_pool))
[ "$max_connections" = "$PG_MAX_CONNECTIONS" ] || fail max_connections_changed
[ "$reserved" = "$PG_RESERVED_CONNECTIONS" ] || fail reserved_connections_changed
[ "$ordinary" = "$PG_ORDINARY_CONNECTIONS" ] || fail ordinary_capacity_wrong
[ "$a_backends" = "$A_AGGREGATE_POOL" ] || fail aggregate_backend_count_wrong
[ "$replica_groups" = "$A_REPLICA_COUNT" ] || fail replica_group_count_wrong
[ "$min_pool" = "$A_POOL_PER_REPLICA" ] || fail replica_pool_min_wrong
[ "$max_pool" = "$A_POOL_PER_REPLICA" ] || fail replica_pool_max_wrong
[ "$headroom" = 1 ] || fail ordinary_headroom_not_one
[ "$one_replica_release_headroom" -lt "$B_COHORT_SIZE" ] \
  || fail one_replica_release_would_satisfy_b
printf 'ordinary=%s aggregate_a=%s headroom=%s pool_per_replica=%s headroom_after_one_replica=%s b_required=%s\n' \
  "$ordinary" "$a_backends" "$headroom" "$max_pool" \
  "$one_replica_release_headroom" "$B_COHORT_SIZE" \
  > "$EVIDENCE/aggregate_capacity.txt"

# The unchanged B command must fail while forming its atomic session cohort.
joint_output="$EVIDENCE/b_with_a"
set +e
run_b "$joint_output" b_with_a
joint_rc=$?
set -e
printf '%s\n' "$joint_rc" > "$EVIDENCE/b_with_a.rc"
[ "$joint_rc" -eq 12 ] || fail b_with_a_wrong_exit
[ ! -e "$joint_output/manifest.json" ] || fail b_with_a_published_manifest
[ -s "$joint_output/attempt.json" ] || fail b_with_a_attempt_missing

read -r peak completed failures capacity_failures < <(/usr/bin/python3 - \
  "$joint_output/attempt.json" <<'PY'
import json, sys
x = json.load(open(sys.argv[1]))
capacity = [
    failure for failure in x["failures"]
    if failure.get("sqlstate") == "53300"
    and ("remaining connection slots are reserved" in failure.get("message", "")
         or "too many clients already" in failure.get("message", ""))
]
print(x["peak_sessions"], len(x["completed_shards"]), x["failure_count"], len(capacity))
PY
)
[ "$peak" -ge 1 ] || fail b_no_partial_admission_observed
[ "$peak" -lt "$B_COHORT_SIZE" ] || fail b_full_cohort_unexpectedly_formed
[ "$completed" -lt "$B_COHORT_SIZE" ] || fail b_completed_all_shards
[ "$capacity_failures" -ge 1 ] || fail postgres_capacity_error_missing

# Exclude lock blocking and server failure as alternate causes.
psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres --no-password \
  --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT locktype, mode, granted, count(*)
   FROM pg_locks GROUP BY locktype, mode, granted ORDER BY locktype, mode, granted" \
  > "$EVIDENCE/pg_locks_after_b.tsv"
lock_blockers=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_stat_activity
   WHERE datname = '$PG_DATABASE' AND wait_event_type = 'Lock'
     AND cardinality(pg_blocking_pids(pid)) > 0")
[ "$lock_blockers" = 0 ] || fail lock_blocker_graph_present
observer_health=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname="$PG_DATABASE" \
  --no-password --tuples-only --no-align --command \
  "SELECT current_database() || ':' || current_user || ':' || count(*) FROM source_documents")
[ "$observer_health" = "$PG_DATABASE:$PG_SUPERUSER:20000" ] || fail reserved_observer_unhealthy

sleep 0.5
bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/peer_after_b.txt"
B_WITH_A_BLOCKED=1

# Release the complete deployment normally and prove unchanged B recovers.
bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/stop_a.txt" 2>&1
started=0
remaining=-1
for _ in $(seq 1 80); do
  remaining=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
    --no-password --tuples-only --no-align --command \
    "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'document-index/%'")
  [ "$remaining" = 0 ] && break
  sleep 0.1
done
[ "$remaining" = 0 ] || fail a_connections_not_released

recovery_output="$EVIDENCE/b_after_release"
run_b "$recovery_output" b_after_release || fail b_after_release_command_failed
bash "$ROOT/eval/task_check_b.sh" "$recovery_output" \
  > "$EVIDENCE/b_after_release_grade.txt" 2>&1 || fail b_after_release_audit_invalid

trap - EXIT
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_AFTER_RELEASE_OK=1 RESOURCE=postgres_connection_pool REASON=aggregate_replica_pools_exhaust_ordinary_connection_slots MAX_CONNECTIONS=$max_connections RESERVED=$reserved ORDINARY=$ordinary REPLICAS=$replica_groups POOL_PER_REPLICA=$max_pool A_BACKENDS=$a_backends HEADROOM=$headroom ONE_REPLICA_RELEASE_HEADROOM=$one_replica_release_headroom B_REQUIRED=$B_COHORT_SIZE B_PEAK=$peak B_CAPACITY_FAILURES=$capacity_failures LOCK_BLOCKERS=$lock_blockers"
