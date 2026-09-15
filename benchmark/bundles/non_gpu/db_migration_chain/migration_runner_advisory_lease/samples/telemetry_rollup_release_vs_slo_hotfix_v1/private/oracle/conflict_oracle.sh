#!/usr/bin/env bash
set -euo pipefail
evidence="$RESULT_ROOT/evidence/telemetry_construction"
work=/tmp/telemetry-construction
mkdir -p "$evidence"
rm -rf "$work"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 "$work"
b_report="$work/b-report.json"
b_command=(/work/repo/bin/telemetry-migrate apply-slo-hotfix --report "$b_report")
printf '%q ' "${b_command[@]}" >"$evidence/b_command.txt"; printf '\n' >>"$evidence/b_command.txt"

reset_db() {
  bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
  psql -X -qAt -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='$DB_NAME' and pid<>pg_backend_pid()" >/dev/null || true
  dropdb --if-exists "$DB_NAME"
  createdb "$DB_NAME"
  psql -X -q -v ON_ERROR_STOP=1 -d "$DB_NAME" -f "$CASE_PRIVATE_ROOT/data/seed.sql" >/dev/null
  rm -f "$A_RUNTIME/client.pid" "$b_report"
}
run_b() {
  runuser -u "$AGENT_USER" -- env PGHOST="$PGHOST" PGPORT="$PGPORT" PGUSER="$PGUSER" DB_NAME="$DB_NAME" "${b_command[@]}"
}

reset_db
run_b >"$evidence/b_alone.stdout" 2>"$evidence/b_alone.stderr"
cp "$b_report" "$evidence/b_alone_report.json"
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from schema_history where version='V20260804_150' and checksum='sha256:slo-burn-window-20260804-150'")" = 1
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from migration_audit where version='V20260804_150' and acquired_lock")" = 1
b_alone_ok=1

reset_db
A_STEP_SLEEP=1.2 bash "$CASE_PRIVATE_ROOT/a/start_a.sh" >"$evidence/a_start.txt"
ready=0
for _ in $(seq 1 140); do
  if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$evidence/a_ready.txt" 2>&1; then ready=1; break; fi
  sleep 0.1
done
test "$ready" = 1
bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" >"$evidence/a_trust.txt"
cp "$TRUST_PATH" "$evidence/a_trust.json"
before_history=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from schema_history where version between 'V20260804_101' and 'V20260804_105'")
read -r backend_before client_before < <(python3 - "$TRUST_PATH" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print(d["backend_pid"],d["client_pid"])
PY
)
set +e
run_b >"$evidence/b_with_a.stdout" 2>"$evidence/b_with_a.stderr"
b_with_a_rc=$?
set -e
cp "$b_report" "$evidence/b_with_a_report.json"
test "$b_with_a_rc" -ne 0
python3 - "$b_report" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d.get("lock_wait_result")=="migration_lock_timeout"
assert d.get("applied_version") is None
PY
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from schema_history where version='V20260804_150'")" = 0
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from information_schema.columns where table_name='telemetry_series' and column_name='slo_burn_window'")" = 0
after_history=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from schema_history where version between 'V20260804_101' and 'V20260804_105'")
test "$after_history" -gt "$before_history"
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from pg_locks where locktype='advisory' and granted and pid=$backend_before and objid=820260804")" = 1
kill -0 "$client_before"
bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" >"$evidence/peer_after_block.txt"

completed=0
for _ in $(seq 1 160); do
  state=$(psql -X -qAt -d "$DB_NAME" -c "select status from release_state where namespace='observability_catalog'" 2>/dev/null || true)
  if [ "$state" = completed ]; then completed=1; break; fi
  sleep 0.1
done
test "$completed" = 1
for _ in $(seq 1 30); do kill -0 "$client_before" 2>/dev/null || break; sleep 0.1; done
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from pg_locks where locktype='advisory' and granted and pid=$backend_before and objid=820260804")" = 0
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from schema_history where version between 'V20260804_101' and 'V20260804_105'")" = 5
cp "$b_report" "$evidence/b_with_a_report_preserved.json"
rm -f "$b_report"
run_b >"$evidence/b_recovery.stdout" 2>"$evidence/b_recovery.stderr"
cp "$b_report" "$evidence/b_recovery_report.json"
python3 - "$b_report" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d.get("lock_wait_result")=="applied"
assert d.get("applied_version")=="V20260804_150"
PY
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from schema_history where version='V20260804_150' and checksum='sha256:slo-burn-window-20260804-150'")" = 1
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=%s B_WITH_A_BLOCKED=1 RESOURCE=db_migration_chain REASON=postgres_advisory_lock_timeout RECOVERY_OK=1 client_pid=%s backend_pid=%s history_before=%s history_after=%s\n' "$b_alone_ok" "$client_before" "$backend_before" "$before_history" "$after_history"
