#!/bin/bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
definition=$(mysql --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password --batch --skip-column-names --execute "SELECT CONCAT(NON_UNIQUE,':',GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ','),':',COUNT(*)) FROM information_schema.statistics WHERE TABLE_SCHEMA='$LIVE_DB' AND TABLE_NAME='$TARGET_TABLE' AND INDEX_NAME='$REQUESTED_INDEX' GROUP BY NON_UNIQUE" 2>/tmp/registry_task_index.err)
definition_rc=$?
migration=$(mysql --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password --batch --skip-column-names --database="$LIVE_DB" --execute "SELECT version FROM $MIGRATIONS_TABLE WHERE version='$REQUESTED_MIGRATION'" 2>/tmp/registry_task_migration.err)
migration_rc=$?
if [ "$definition_rc" -eq 0 ] && [ "$migration_rc" -eq 0 ] && [ "$definition" = "1:tenant_key,serving_status,activated_at:3" ] && [ "$migration" = "$REQUESTED_MIGRATION" ]; then
  echo "TASK_OK=1 DATABASE=$LIVE_DB TABLE=$TARGET_TABLE INDEX=$REQUESTED_INDEX DEFINITION=$definition MIGRATION=$migration"
else
  echo "TASK_OK=0 DATABASE=$LIVE_DB TABLE=$TARGET_TABLE INDEX=$REQUESTED_INDEX DEFINITION=${definition:-absent} MIGRATION=${migration:-absent}"
  exit 1
fi
