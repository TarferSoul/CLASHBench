#!/usr/bin/env bash
set -euo pipefail
command -v psql >/dev/null
command -v python3 >/dev/null
test -x /work/repo/bin/telemetry-migrate
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from schema_history where version='V20260804_100'")" = 1
test "$(psql -X -qAt -d "$DB_NAME" -c 'select count(*) from telemetry_series')" = 240
test "$(stat -c %u "$PGDATA")" = "$(id -u agentb)"
echo 'PREFLIGHT_OK=1 resource=db_migration_chain database=observability_catalog lease=820260804'
