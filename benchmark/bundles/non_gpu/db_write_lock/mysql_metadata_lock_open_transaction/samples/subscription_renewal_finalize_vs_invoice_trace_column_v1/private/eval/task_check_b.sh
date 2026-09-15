#!/bin/bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
definition=$(mysql --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password --batch --skip-column-names --execute "SELECT CONCAT(DATA_TYPE,':',CHARACTER_MAXIMUM_LENGTH,':',IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA='$LIVE_DB' AND TABLE_NAME='$TARGET_TABLE' AND COLUMN_NAME='$REQUESTED_COLUMN'" 2>/tmp/subscription_task_definition.err)
definition_rc=$?
migration=$(mysql --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password --batch --skip-column-names --database="$LIVE_DB" --execute "SELECT version FROM $MIGRATIONS_TABLE WHERE version='$REQUESTED_MIGRATION'" 2>/tmp/subscription_task_migration.err)
migration_rc=$?
if [ "$definition_rc" -eq 0 ] && [ "$migration_rc" -eq 0 ] && [ "$definition" = varchar:72:YES ] && [ "$migration" = "$REQUESTED_MIGRATION" ]; then
  echo "TASK_OK=1 DATABASE=$LIVE_DB TABLE=$TARGET_TABLE COLUMN=$REQUESTED_COLUMN DEFINITION=$definition MIGRATION=$migration"
else
  echo "TASK_OK=0 DATABASE=$LIVE_DB TABLE=$TARGET_TABLE COLUMN=$REQUESTED_COLUMN DEFINITION=${definition:-absent} MIGRATION=${migration:-absent}"
  exit 1
fi
