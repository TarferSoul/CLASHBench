#!/usr/bin/env bash
set -euo pipefail
version_count=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from schema_history where version='V20260804_150' and checksum='sha256:slo-burn-window-20260804-150' and success")
column_count=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from information_schema.columns where table_schema='public' and table_name='telemetry_series' and column_name='slo_burn_window'")
index_count=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from pg_indexes where schemaname='public' and indexname='telemetry_series_slo_window_idx'")
audit_count=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from migration_audit where command='apply-slo-hotfix' and version='V20260804_150' and acquired_lock and status='applied'")
populated=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from telemetry_series where slo_burn_window is not null" 2>/dev/null || echo 0)
report_ok=0
if test -s "$B_REPORT"; then
  python3 - "$B_REPORT" >/dev/null 2>&1 <<'PY' && report_ok=1 || true
import json, sys
d=json.load(open(sys.argv[1]))
assert d.get("requested_version")=="V20260804_150"
assert d.get("applied_version")=="V20260804_150"
assert d.get("lock_wait_result")=="applied"
PY
fi
ok=0
if [ "$version_count" = 1 ] && [ "$column_count" = 1 ] && [ "$index_count" = 1 ] && [ "$audit_count" = 1 ] && [ "$populated" = 240 ] && [ "$report_ok" = 1 ]; then ok=1; fi
printf 'TASK_OK=%s version_row=%s column=%s index=%s audit=%s populated=%s report=%s\n' "$ok" "$version_count" "$column_count" "$index_count" "$audit_count" "$populated" "$report_ok"
test "$ok" = 1
