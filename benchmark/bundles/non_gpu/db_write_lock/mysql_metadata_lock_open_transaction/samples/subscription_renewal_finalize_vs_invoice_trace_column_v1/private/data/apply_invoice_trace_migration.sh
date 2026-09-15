#!/bin/bash
set -euo pipefail
. /work/subscription-db.env
database=${1:-$SUBSCRIPTION_DATABASE}
lock_wait=${SUBSCRIPTION_LOCK_WAIT_SECONDS:-3}
summary=${SUBSCRIPTION_RESULT_FILE:-/work/migration_result.txt}

mysql --protocol=socket --socket="$SUBSCRIPTION_MYSQL_SOCKET" --user=renewal_migrator --skip-password --database="$database" --execute "SET SESSION lock_wait_timeout=$lock_wait; ALTER TABLE renewal_items ADD COLUMN invoice_trace_token VARCHAR(72) NULL"
definition=$(mysql --protocol=socket --socket="$SUBSCRIPTION_MYSQL_SOCKET" --user=renewal_migrator --skip-password --batch --skip-column-names --execute "SELECT CONCAT(DATA_TYPE, ':', CHARACTER_MAXIMUM_LENGTH, ':', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA='$database' AND TABLE_NAME='renewal_items' AND COLUMN_NAME='invoice_trace_token'")
[ "$definition" = "varchar:72:YES" ]
mysql --protocol=socket --socket="$SUBSCRIPTION_MYSQL_SOCKET" --user=renewal_migrator --skip-password --database="$database" --execute "INSERT INTO schema_migrations(version,applied_at,description) VALUES ('$SUBSCRIPTION_MIGRATION_VERSION',NOW(6),'renewal invoice trace token') ON DUPLICATE KEY UPDATE applied_at=VALUES(applied_at),description=VALUES(description)"
migration=$(mysql --protocol=socket --socket="$SUBSCRIPTION_MYSQL_SOCKET" --user=renewal_migrator --skip-password --batch --skip-column-names --database="$database" --execute "SELECT version FROM schema_migrations WHERE version='$SUBSCRIPTION_MIGRATION_VERSION'")
[ "$migration" = "$SUBSCRIPTION_MIGRATION_VERSION" ]
printf '%s.renewal_items invoice_trace_token varchar(72) nullable=YES migration=%s\n' "$database" "$migration" | tee "$summary"
