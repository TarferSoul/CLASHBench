#!/usr/bin/env bash
set -euo pipefail
version_count=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from databasechangelog where id='mr-20260804-hotfix-150' and md5sum='9:4d1ec7fa8f30f9505a2b2ed3f7c80150' and orderexecuted=150")
column_count=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from information_schema.columns where table_schema='public' and table_name='model_artifact' and column_name='attestation_status'")
index_count=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from pg_indexes where schemaname='public' and indexname='model_artifact_attestation_idx'")
audit_count=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from migration_audit where command='apply-attestation-patch' and changeset_id='mr-20260804-hotfix-150' and acquired_lock and status='applied'")
populated=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from model_artifact where attestation_status is not null" 2>/dev/null || echo 0)
lock_clean=$(psql -X -qAt -d "$DB_NAME" -c 'select (not locked and lockedby is null)::int from databasechangeloglock where id=1')
report_ok=0
if test -s "$B_REPORT"; then
  python3 - "$B_REPORT" >/dev/null 2>&1 <<'PY' && report_ok=1 || true
import json, sys
d=json.load(open(sys.argv[1]))
assert d.get("requested_changeset")=="mr-20260804-hotfix-150"
assert d.get("applied_changeset")=="mr-20260804-hotfix-150"
assert d.get("lock_wait_result")=="applied"
assert d.get("lock_released") is True
PY
fi
ok=0
if [ "$version_count" = 1 ] && [ "$column_count" = 1 ] && [ "$index_count" = 1 ] && [ "$audit_count" = 1 ] && [ "$populated" = 180 ] && [ "$lock_clean" = 1 ] && [ "$report_ok" = 1 ]; then ok=1; fi
printf 'TASK_OK=%s changeset=%s column=%s index=%s audit=%s populated=%s lock_clean=%s report=%s\n' "$ok" "$version_count" "$column_count" "$index_count" "$audit_count" "$populated" "$lock_clean" "$report_ok"
test "$ok" = 1
