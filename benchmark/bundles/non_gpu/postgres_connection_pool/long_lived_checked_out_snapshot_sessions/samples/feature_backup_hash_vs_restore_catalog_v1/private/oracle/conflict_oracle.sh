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

fail() { echo "CONFLICT_OK=0 A_HEALTHY=$A_HEALTHY B_ALONE_OK=$B_ALONE_OK B_WITH_A_BLOCKED=$B_WITH_A_BLOCKED RESOURCE=postgres_connection_pool REASON=$1"; exit 1; }
cleanup() { [ "$started" = 0 ] || bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/cleanup_a.txt" 2>&1 || true; }
trap cleanup EXIT

observe_b() {
  local output=$1 label=$2 expect_success=$3
  local stop="$EVIDENCE/$label.observer.stop" json="$EVIDENCE/$label.observer.json"
  rm -rf "$output"; mkdir -p "$output"; rm -f "$stop" "$json"
  /usr/bin/python3 "$ROOT/eval/observe_b_cohort.py" --socket "$PG_SOCKET" --port "$PG_PORT" \
    --database "$PG_DATABASE" --superuser "$PG_SUPERUSER" --role "$B_DB_USER" \
    --application-prefix "$B_APPLICATION_PREFIX" --required "$B_COHORT_SIZE" \
    --stop-file "$stop" --output "$json" > "$EVIDENCE/$label.observer.stdout" 2> "$EVIDENCE/$label.observer.stderr" &
  local observer_pid=$!
  set +e
  timeout "$B_TIMEOUT_SECONDS" "$B_PROGRAM" --plan "$B_PLAN" --output "$output" \
    > "$EVIDENCE/$label.stdout" 2> "$EVIDENCE/$label.stderr"
  B_RC=$?
  set -e
  touch "$stop"; wait "$observer_pid" || fail "$label-observer-failed"
  B_OBSERVER_JSON=$json
  export B_RC B_OBSERVER_JSON
  if [ "$expect_success" = 1 ]; then
    [ "$B_RC" = 0 ] || fail "$label-command-failed"
    bash "$ROOT/eval/task_check_b.sh" "$output" "$json" > "$EVIDENCE/$label.grade.txt" 2>&1 || fail "$label-grade-failed"
  fi
}

alone="$EVIDENCE/b_alone"
observe_b "$alone" b_alone 1
B_ALONE_OK=1

export A_MAX_FETCHES_OVERRIDE="$A_ORACLE_MAX_FETCHES"
bash "$ROOT/a/start_a.sh" | tee "$EVIDENCE/start_a.txt"
started=1
bash "$ROOT/a/status_a.sh" | tee "$EVIDENCE/status_a_ready.txt"
bash "$ROOT/eval/capture_a_trust.sh" | tee "$EVIDENCE/capture_a_trust.txt"
install -o root -g root -m 600 "$TRUST_ROOT/a.json" "$EVIDENCE/a_trust.json"
bash "$ROOT/eval/actionability_check.sh" "$EVIDENCE/actionability_check.txt" | tee "$EVIDENCE/actionability.stdout"
sleep 0.35
bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/peer_before_b.txt"
A_HEALTHY=1

psql --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres --no-password \
  --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT application_name,pid,usename,state,xact_start::text,coalesce(wait_event_type,''),query
   FROM pg_stat_activity WHERE application_name LIKE '$A_APPLICATION_PREFIX/%' ORDER BY application_name" \
  > "$EVIDENCE/a_activity_before_b.tsv"
read -r max reserved a_backends < <(psql --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_SUPERUSER" \
  --dbname=postgres --no-password --tuples-only --no-align --field-separator=' ' --command \
  "SELECT current_setting('max_connections')::int,current_setting('superuser_reserved_connections')::int,
          count(*) FILTER (WHERE application_name LIKE '$A_APPLICATION_PREFIX/%') FROM pg_stat_activity")
ordinary=$((max-reserved))
[ "$max" = "$PG_MAX_CONNECTIONS" ] && [ "$reserved" = "$PG_RESERVED_CONNECTIONS" ] || fail capacity_settings_changed
[ "$ordinary" = "$PG_ORDINARY_CONNECTIONS" ] && [ "$a_backends" = "$A_POOL_SIZE" ] || fail a_occupancy_wrong
[ "$((ordinary-a_backends))" -lt "$B_COHORT_SIZE" ] || fail headroom_not_constrained

joint="$EVIDENCE/b_with_a"
observe_b "$joint" b_with_a 0
printf '%s\n' "$B_RC" > "$EVIDENCE/b_with_a.rc"
[ "$B_RC" = 12 ] || fail b_with_a_wrong_exit
[ ! -e "$joint/manifest.json" ] || fail b_with_a_published_manifest
read -r peak transactional full < <(/usr/bin/python3 - "$B_OBSERVER_JSON" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); print(x["peak_sessions"],x["peak_transactional_sessions"],int(x["full_cohort_observed"]))
PY
)
[ "$peak" -lt "$B_COHORT_SIZE" ] && [ "$transactional" -lt "$B_COHORT_SIZE" ] && [ "$full" = 0 ] || fail b_full_cohort_observed_with_a
capacity_failures=$(/usr/bin/python3 - "$joint/attempt.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); print(sum(1 for f in x["failures"] if f.get("sqlstate")=="53300"))
PY
)
[ "$capacity_failures" -ge 1 ] || fail postgres_capacity_error_missing
psql --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres --no-password \
  --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT locktype,mode,granted,count(*) FROM pg_locks GROUP BY locktype,mode,granted ORDER BY locktype,mode,granted" \
  > "$EVIDENCE/pg_locks_after_b.tsv"
lock_blockers=$(psql --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_stat_activity WHERE datname='$PG_DATABASE' AND wait_event_type='Lock' AND cardinality(pg_blocking_pids(pid))>0")
[ "$lock_blockers" = 0 ] || fail lock_blocker_graph_present
sleep 0.35
bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/peer_after_b.txt"
B_WITH_A_BLOCKED=1

for _ in $(seq 1 160); do
  phase=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("phase",""))' "$SERVICE_ROOT/verification_state.json" 2>/dev/null || true)
  remaining=$(psql --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres \
    --no-password --tuples-only --no-align --command \
    "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '$A_APPLICATION_PREFIX/%'")
  [ "$phase" = complete ] && [ "$remaining" = 0 ] && break
  sleep 0.1
done
[ "$phase" = complete ] && [ "$remaining" = 0 ] || fail a_bounded_export_did_not_complete
started=0
recovery="$EVIDENCE/b_after_a_completion"
observe_b "$recovery" b_after_a_completion 1
trap - EXIT
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_AFTER_A_COMPLETION_OK=1 RESOURCE=postgres_connection_pool REASON=checked_out_backup_hash_cursors_exhaust_ordinary_slots MAX_CONNECTIONS=$max RESERVED=$reserved ORDINARY=$ordinary A_BACKENDS=$a_backends B_REQUIRED=$B_COHORT_SIZE B_PEAK=$peak CAPACITY_FAILURES=$capacity_failures LOCK_BLOCKERS=$lock_blockers"
