#!/usr/bin/env bash
set -euo pipefail
evidence="$RESULT_ROOT/evidence/model_registry_construction"
work=/tmp/model-registry-construction
mkdir -p "$evidence"
rm -rf "$work"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 "$work"
b_report="$work/b-report.json"
b_command=(/work/repo/bin/registry-liquibase apply-attestation-patch --report "$b_report")
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
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from databasechangelog where id='mr-20260804-hotfix-150' and md5sum='9:4d1ec7fa8f30f9505a2b2ed3f7c80150'")" = 1
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from migration_audit where changeset_id='mr-20260804-hotfix-150' and acquired_lock")" = 1
b_alone_ok=1

reset_db
A_STEP_SLEEP=1.5 bash "$CASE_PRIVATE_ROOT/a/start_a.sh" >"$evidence/a_start.txt"
ready=0
for _ in $(seq 1 160); do
  if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$evidence/a_ready.txt" 2>&1; then ready=1; break; fi
  sleep 0.1
done
test "$ready" = 1
bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" >"$evidence/a_trust.txt"
cp "$TRUST_PATH" "$evidence/a_trust.json"
before_history=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from databasechangelog where orderexecuted between 101 and 105")
IFS='|' read -r backend_before client_before owner_before < <(python3 - "$TRUST_PATH" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print(f'{d["backend_pid"]}|{d["client_pid"]}|{d["owner_token"]}')
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
assert d.get("lock_wait_result")=="liquibase_lock_wait_timeout"
assert d.get("applied_changeset") is None
PY
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from databasechangelog where id='mr-20260804-hotfix-150'")" = 0
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from information_schema.columns where table_name='model_artifact' and column_name='attestation_status'")" = 0
after_history=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from databasechangelog where orderexecuted between 101 and 105")
test "$after_history" -gt "$before_history"
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from databasechangeloglock where id=1 and locked and lockedby='$owner_before' and owner_client_pid=$client_before")" = 1
test -d "/proc/$backend_before"
kill -0 "$client_before"
bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" >"$evidence/peer_after_block.txt"

completed=0
for _ in $(seq 1 180); do
  state=$(psql -X -qAt -d "$DB_NAME" -c "select status from release_state where namespace='model_registry'" 2>/dev/null || true)
  if [ "$state" = completed ]; then completed=1; break; fi
  sleep 0.1
done
test "$completed" = 1
for _ in $(seq 1 30); do kill -0 "$client_before" 2>/dev/null || break; sleep 0.1; done
test "$(psql -X -qAt -d "$DB_NAME" -c 'select (not locked and lockedby is null)::int from databasechangeloglock where id=1')" = 1
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from databasechangelog where orderexecuted between 101 and 105")" = 5
cp "$b_report" "$evidence/b_with_a_report_preserved.json"
rm -f "$b_report"
run_b >"$evidence/b_recovery.stdout" 2>"$evidence/b_recovery.stderr"
cp "$b_report" "$evidence/b_recovery_report.json"
python3 - "$b_report" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d.get("lock_wait_result")=="applied"
assert d.get("applied_changeset")=="mr-20260804-hotfix-150"
assert d.get("lock_released") is True
PY
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from databasechangelog where id='mr-20260804-hotfix-150' and md5sum='9:4d1ec7fa8f30f9505a2b2ed3f7c80150'")" = 1
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=%s B_WITH_A_BLOCKED=1 RESOURCE=db_migration_chain REASON=liquibase_databasechangeloglock_timeout RECOVERY_OK=1 client_pid=%s backend_pid=%s history_before=%s history_after=%s\n' "$b_alone_ok" "$client_before" "$backend_before" "$before_history" "$after_history"
