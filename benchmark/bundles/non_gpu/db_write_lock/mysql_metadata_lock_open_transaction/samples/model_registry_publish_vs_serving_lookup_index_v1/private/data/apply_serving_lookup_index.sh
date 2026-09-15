#!/bin/bash
set -euo pipefail
. /work/model-registry-db.env
database=${1:-$REGISTRY_DATABASE}
lock_wait=${REGISTRY_LOCK_WAIT_SECONDS:-3}
summary=${REGISTRY_RESULT_FILE:-/work/index_migration_result.txt}
mysql --protocol=socket --socket="$REGISTRY_MYSQL_SOCKET" --user=registry_migrator --skip-password --database="$database" --execute "SET SESSION lock_wait_timeout=$lock_wait; ALTER TABLE model_versions ADD INDEX ix_model_versions_serving_lookup (tenant_key, serving_status, activated_at)"
definition=$(mysql --protocol=socket --socket="$REGISTRY_MYSQL_SOCKET" --user=registry_migrator --skip-password --batch --skip-column-names --execute "SELECT CONCAT(NON_UNIQUE,':',GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ','),':',COUNT(*)) FROM information_schema.statistics WHERE TABLE_SCHEMA='$database' AND TABLE_NAME='model_versions' AND INDEX_NAME='ix_model_versions_serving_lookup' GROUP BY NON_UNIQUE")
[ "$definition" = "1:tenant_key,serving_status,activated_at:3" ]
mysql --protocol=socket --socket="$REGISTRY_MYSQL_SOCKET" --user=registry_migrator --skip-password --database="$database" --execute "INSERT INTO schema_migrations(version,applied_at,description) VALUES ('$REGISTRY_MIGRATION_VERSION',NOW(6),'model serving lookup index') ON DUPLICATE KEY UPDATE applied_at=VALUES(applied_at),description=VALUES(description)"
migration=$(mysql --protocol=socket --socket="$REGISTRY_MYSQL_SOCKET" --user=registry_migrator --skip-password --batch --skip-column-names --database="$database" --execute "SELECT version FROM schema_migrations WHERE version='$REGISTRY_MIGRATION_VERSION'")
[ "$migration" = "$REGISTRY_MIGRATION_VERSION" ]
printf '%s.model_versions ix_model_versions_serving_lookup non_unique=1 columns=tenant_key,serving_status,activated_at migration=%s\n' "$database" "$migration" | tee "$summary"
