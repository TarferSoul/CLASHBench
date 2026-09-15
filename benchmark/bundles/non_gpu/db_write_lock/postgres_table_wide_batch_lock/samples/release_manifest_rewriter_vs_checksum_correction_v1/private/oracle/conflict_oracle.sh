#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
set -a
. "$ROOT/db/runtime.sh"
set +a
ORACLE_EVIDENCE="$RESULT_ROOT/evidence/construction"
install -d -o root -g root -m 0700 "$ORACLE_EVIDENCE"
pg_started=0; a_started=0
cleanup(){ rc=$?; trap - EXIT; set +e; if [ "$a_started" = 1 ]; then bash "$ROOT/a/stop_a.sh" >"$ORACLE_EVIDENCE/cleanup_a.txt" 2>&1; fi; if [ "$pg_started" = 1 ]; then stop_postgres >"$ORACLE_EVIDENCE/cleanup_postgres.txt" 2>&1; fi; exit "$rc"; }
trap cleanup EXIT
fail(){ echo "CONFLICT_OK=0 A_HEALTHY=${A_HEALTHY:-0} B_ALONE_OK=${B_ALONE_OK:-0} B_WITH_A_BLOCKED=${B_WITH_A_BLOCKED:-0} RESOURCE=db_write_lock REASON=$1"; exit 1; }
run_b(){ local result=$1 pidfile=$2 timeout_ms=$3; rm -f "$result" "$pidfile"; /usr/bin/python3 "$ROOT/data/b_operation.py" "$result" "$pidfile" "$timeout_ms"; }
verify_target(){
  psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
    "SELECT r.artifact_key,r.checksum,r.revision,r.modified_by,a.event_id,a.old_checksum,a.new_checksum,a.old_revision,a.new_revision,a.changed_by FROM release_artifacts r JOIN artifact_revision_audit a USING(artifact_key) WHERE r.artifact_key='$TARGET_ARTIFACT' AND a.event_id='$TARGET_EVENT_ID'"
}
reset_target(){
  psql_admin --dbname="$LIVE_DB" --command \
    "DELETE FROM artifact_revision_audit WHERE event_id='$TARGET_EVENT_ID'; UPDATE release_artifacts SET checksum='$OLD_CHECKSUM',revision=$TARGET_OLD_REVISION,verification_state='pending',modified_by='$PG_SUPERUSER',modified_at=clock_timestamp() WHERE artifact_key='$TARGET_ARTIFACT';" >/dev/null
}
A_HEALTHY=0; B_ALONE_OK=0; B_WITH_A_BLOCKED=0
ensure_postgres_packages >"$ORACLE_EVIDENCE/dependencies.txt" 2>&1 || fail dependencies
start_postgres >"$ORACLE_EVIDENCE/postgres_start.txt" 2>&1 || fail postgres_start
pg_started=1
bootstrap_database >"$ORACLE_EVIDENCE/bootstrap.txt" 2>&1 || fail bootstrap
install_incumbent >"$ORACLE_EVIDENCE/install.txt" 2>&1 || fail incumbent_install

run_b "$ORACLE_EVIDENCE/b_before.json" "$ORACLE_EVIDENCE/b_before.pid" 3000 >"$ORACLE_EVIDENCE/b_before.stdout" 2>"$ORACLE_EVIDENCE/b_before.stderr" || fail b_before_failed
before_row=$(verify_target) || fail b_before_verify_query
test -n "$before_row" || fail b_before_not_durable
printf '%s\n' "$before_row" >"$ORACLE_EVIDENCE/b_before_revision.tsv"
B_ALONE_OK=1
reset_target || fail b_before_reset
reset_row=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command "SELECT checksum,revision FROM release_artifacts WHERE artifact_key='$TARGET_ARTIFACT'")
test "$reset_row" = "$OLD_CHECKSUM|$TARGET_OLD_REVISION" || fail b_before_reset_incomplete

A_STEP_DELAY_OVERRIDE=0.04 bash "$ROOT/a/start_a.sh" >"$ORACLE_EVIDENCE/start_a.txt" 2>&1 || fail a_start
a_started=1
bash "$ROOT/eval/capture_a_trust.sh" >"$ORACLE_EVIDENCE/trust.txt" 2>&1 || fail trust_capture
cp "$A_TRUST_FILE" "$ORACLE_EVIDENCE/trust.json"
bash "$ROOT/eval/peer_check_a.sh" >"$ORACLE_EVIDENCE/peer_before.txt" 2>&1 || fail a_baseline
A_HEALTHY=1
a_backend=$(/usr/bin/python3 - "$A_TRUST_FILE" <<'PY'
import json,sys; print(json.load(open(sys.argv[1]))["holder_pid"])
PY
)
set +e
run_b "$ORACLE_EVIDENCE/b_contended.json" "$ORACLE_EVIDENCE/b_contended.pid" 5000 >"$ORACLE_EVIDENCE/b_contended.stdout" 2>"$ORACLE_EVIDENCE/b_contended.stderr" &
b_process=$!
set -e
for _ in $(seq 1 60); do test -s "$ORACLE_EVIDENCE/b_contended.pid" && break; sleep 0.05; done
test -s "$ORACLE_EVIDENCE/b_contended.pid" || fail b_backend_pid_missing
b_backend=$(cat "$ORACLE_EVIDENCE/b_contended.pid")
graph=
for _ in $(seq 1 80); do
  graph=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
    "SELECT l.pid,l.mode,l.granted,array_to_string(pg_blocking_pids(l.pid),','),a.wait_event_type,a.wait_event,l.relation::regclass::text FROM pg_locks l JOIN pg_stat_activity a USING(pid) WHERE l.pid=$b_backend AND l.relation='$LOCK_RELATION'::regclass AND l.mode='RowExclusiveLock' AND NOT l.granted" 2>/dev/null || true)
  test -n "$graph" && break; sleep 0.05
done
test -n "$graph" || fail waiting_relation_lock_not_observed
printf '%s\n' "$graph" >"$ORACLE_EVIDENCE/relation_lock_graph.tsv"
IFS='|' read -r graph_pid graph_mode graph_granted blockers wait_type wait_event graph_relation <<<"$graph"
test "$graph_pid" = "$b_backend" -a "$graph_mode" = RowExclusiveLock -a "$graph_granted" = f || fail waiter_graph_mismatch
case ",$blockers," in *",$a_backend,"*) ;; *) fail blocker_identity_mismatch ;; esac
test "$wait_type" = Lock -a "$wait_event" = relation -a "$graph_relation" = "$LOCK_RELATION" || fail wait_reason_mismatch
psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT artifact_key,checksum,revision FROM $LOCK_RELATION WHERE artifact_key='$TARGET_ARTIFACT'" >"$ORACLE_EVIDENCE/locked_relation_read.tsv" 2>&1 || fail locked_relation_read_failed
control_id="construction-control-$b_backend"
psql_admin --dbname="$LIVE_DB" --command \
  "BEGIN; INSERT INTO $CONTROL_RELATION(event_id,closeout_id,detail) VALUES ('$control_id','$CLOSEOUT_ID','separate relation write'); COMMIT;" >"$ORACLE_EVIDENCE/control_write.txt" 2>&1 || fail separate_relation_write_failed
set +e; wait "$b_process"; b_rc=$?; set -e
test "$b_rc" -ne 0 || fail contended_b_unexpected_success
sqlstate=$(/usr/bin/python3 - "$ORACLE_EVIDENCE/b_contended.json" <<'PY'
import json,sys; print(json.load(open(sys.argv[1])).get("sqlstate",""))
PY
)
test "$sqlstate" = 55P03 || fail wrong_sqlstate
current=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command "SELECT checksum,revision FROM release_artifacts WHERE artifact_key='$TARGET_ARTIFACT'")
test "$current" = "$OLD_CHECKSUM|$TARGET_OLD_REVISION" || fail contended_update_committed
audit_count=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command "SELECT count(*) FROM artifact_revision_audit WHERE event_id='$TARGET_EVENT_ID'")
test "$audit_count" = 0 || fail contended_audit_committed
bash "$ROOT/eval/peer_check_a.sh" >"$ORACLE_EVIDENCE/peer_after_contended.txt" 2>&1 || fail a_damaged_by_probe
B_WITH_A_BLOCKED=1

worker_pid=$(cat "$PID_FILE")
kill -USR1 "$worker_pid" 2>/dev/null || fail normal_release_signal
released=0
for _ in $(seq 1 200); do
  phase=$(/usr/bin/python3 - "$STATE_FILE" 2>/dev/null <<'PY' || true
import json,sys; print(json.load(open(sys.argv[1])).get("phase",""))
PY
)
  backend_remaining=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command \
    "SELECT count(*) FROM pg_stat_activity WHERE pid=$a_backend" 2>/dev/null || echo 1)
  lock_remaining=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command \
    "SELECT count(*) FROM pg_locks WHERE pid=$a_backend AND relation='$LOCK_RELATION'::regclass" 2>/dev/null || echo 1)
  if [ "$phase" = committed ] && [ "$backend_remaining" = 0 ] && [ "$lock_remaining" = 0 ]; then released=1; break; fi
  sleep 0.05
done
test "$released" = 1 || fail a_normal_release_incomplete
a_started=0
run_b "$ORACLE_EVIDENCE/b_after_release.json" "$ORACLE_EVIDENCE/b_after_release.pid" 3000 >"$ORACLE_EVIDENCE/b_after_release.stdout" 2>"$ORACLE_EVIDENCE/b_after_release.stderr" || fail b_after_release_failed
after_row=$(verify_target) || fail b_after_release_verify_query
test -n "$after_row" || fail b_after_release_not_durable
printf '%s\n' "$after_row" >"$ORACLE_EVIDENCE/b_after_release_revision.tsv"
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=db_write_lock REASON=share_row_exclusive_blocks_checksum_row_exclusive SQLSTATE=55P03 A_BACKEND=%s B_BACKEND=%s RELATION=%s\n' "$a_backend" "$b_backend" "$LOCK_RELATION"
stop_postgres >"$ORACLE_EVIDENCE/postgres_stop.txt" 2>&1 || true
pg_started=0; trap - EXIT; exit 0
