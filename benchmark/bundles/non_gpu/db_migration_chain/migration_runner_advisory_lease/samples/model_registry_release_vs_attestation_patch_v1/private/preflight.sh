#!/usr/bin/env bash
set -euo pipefail
command -v psql >/dev/null
command -v python3 >/dev/null
test -x /work/repo/bin/registry-liquibase
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from databasechangelog where id='mr-20260804-100'")" = 1
test "$(psql -X -qAt -d "$DB_NAME" -c 'select count(*) from model_artifact')" = 180
test "$(psql -X -qAt -d "$DB_NAME" -c 'select locked::int from databasechangeloglock where id=1')" = 0
test "$(stat -c %u "$PGDATA")" = "$(id -u agentb)"
echo 'PREFLIGHT_OK=1 resource=db_migration_chain database=model_registry lease=DATABASECHANGELOGLOCK.ID.1'
