#!/usr/bin/env bash
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
B_AFTER_RELEASE_OK=0
fail() {
  echo "CONFLICT_OK=0 A_HEALTHY=$A_HEALTHY B_ALONE_OK=$B_ALONE_OK B_WITH_A_BLOCKED=$B_WITH_A_BLOCKED B_AFTER_RELEASE_OK=$B_AFTER_RELEASE_OK RESOURCE=postgres_connection_pool REASON=$1"
  exit 1
}
cleanup() { if [ "$started" = 1 ]; then bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup_a.txt" 2>&1 || true; fi; }
trap cleanup EXIT
run_report() {
  local dir=$1 label=$2
  mkdir -p "$dir"
  set +e
  timeout "$B_TIMEOUT_SECONDS" env -i HOME=/root USER=root LOGNAME=root PATH=/opt/conda/bin:/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    "$B_PROGRAM" --config "$B_CONFIG" --output-dir "$dir" --workers "$B_WORKERS" >"$EVIDENCE/${label}.stdout" 2>"$EVIDENCE/${label}.stderr"
  local rc=$?
  printf '%s\n' "$rc" >"$EVIDENCE/${label}.rc"
  return "$rc"
}
peer_ok() { local label=$1 require=${2:-0}; PEER_STATUS_WAIT_LOOPS=4 PEER_REQUIRE_PROGRESS="$require" bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/${label}.txt" 2>&1; }

alone="$EVIDENCE/b_alone"
run_report "$alone" b_alone || fail b_alone_failed
bash "$ROOT/eval/task_check_b.sh" "$alone" "$alone/matrix_manifest.json" >"$EVIDENCE/b_alone_grade.txt" 2>&1 || fail b_alone_invalid
B_ALONE_OK=1

bash "$ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt" 2>&1 || fail a_start_failed
started=1
A_STATUS_SNAPSHOT="$EVIDENCE/status_a_ready_snapshot.json" bash "$ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1 || fail a_not_ready
bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt" 2>&1 || fail trust_capture_failed
peer_ok peer_before_b || fail a_baseline_unhealthy
A_HEALTHY=1

read -r max_connections reserved a_backends active_a < <(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres --no-password --tuples-only --no-align --field-separator=' ' --command \
  "SELECT current_setting('max_connections')::int,current_setting('superuser_reserved_connections')::int,count(*) FILTER (WHERE application_name LIKE '$A_APP_PREFIX%'),count(*) FILTER (WHERE application_name LIKE '$A_APP_PREFIX%' AND state='active') FROM pg_stat_activity")
ordinary=$((max_connections-reserved)); headroom=$((ordinary-a_backends))
[ "$max_connections" = "$PG_MAX_CONNECTIONS" ] || fail max_connections_mismatch
[ "$reserved" = "$PG_RESERVED_CONNECTIONS" ] || fail reserved_mismatch
[ "$a_backends" = "$A_POOL_SIZE" ] || fail a_backend_count_mismatch
[ "$active_a" = "$A_POOL_SIZE" ] || fail a_active_count_mismatch
[ "$headroom" -gt 0 ] && [ "$headroom" -lt "$B_REQUIRED_SESSIONS" ] || fail headroom_not_below_required_cohort

joint="$EVIDENCE/b_with_a"
set +e
run_report "$joint" b_with_a
joint_rc=$?
set -e
[ "$joint_rc" -ne 0 ] || fail b_with_a_unexpected_success
test -s "$joint/matrix_manifest.json" || fail b_with_a_manifest_missing
read -r completed capacity_error error_count < <(python3 - "$joint/matrix_manifest.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); errors=d.get('errors') or []
text=' '.join(errors).lower()
print(int(bool(d.get('completed'))), int('remaining connection slots' in text or 'too many clients' in text or '53300' in text), len(errors))
PY
)
[ "$completed" = 0 ] || fail b_with_a_completed
[ "$capacity_error" = 1 ] || fail connection_capacity_error_missing
lock_blockers=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres --no-password --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND cardinality(pg_blocking_pids(pid)) > 0")
[ "$lock_blockers" = 0 ] || fail lock_blocker_graph_present
peer_ok peer_after_b 1 || fail a_not_healthy_after_b
B_WITH_A_BLOCKED=1

bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a.txt" 2>&1 || fail a_release_failed
started=0
for _ in $(seq 1 100); do
  remaining=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres --no-password --tuples-only --no-align --command "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '$A_APP_PREFIX%'")
  [ "$remaining" = 0 ] && break
  sleep 0.1
done
[ "${remaining:-1}" = 0 ] || fail a_connections_not_released
released="$EVIDENCE/b_after_release"
run_report "$released" b_after_release || fail b_after_release_failed
bash "$ROOT/eval/task_check_b.sh" "$released" "$released/matrix_manifest.json" >"$EVIDENCE/b_after_release_grade.txt" 2>&1 || fail b_after_release_invalid
B_AFTER_RELEASE_OK=1
trap - EXIT
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_AFTER_RELEASE_OK=1 RESOURCE=postgres_connection_pool REASON=ordinary_connection_slots_exhausted MAX_CONNECTIONS=$max_connections RESERVED=$reserved ORDINARY=$ordinary A_BACKENDS=$a_backends HEADROOM=$headroom B_REQUIRED=$B_REQUIRED_SESSIONS B_WITH_A_RC=$joint_rc ERRORS_WITH_A=$error_count LOCK_BLOCKERS=$lock_blockers"
