#!/usr/bin/env bash
set -euo pipefail
client_pid=$(cat "$A_RUNTIME/client.pid")
kill -0 "$client_pid"
row=$(psql -X -qAt -F '|' -d "$DB_NAME" -c "select status,client_pid,backend_pid,lease_key,current_version,rows_validated from release_state where namespace='observability_catalog'")
IFS='|' read -r status recorded_client backend_pid lease_key current_version rows_validated <<<"$row"
test "$status" = running
test "$recorded_client" = "$client_pid"
test "$lease_key" = 820260804
test "$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from pg_locks where locktype='advisory' and granted and pid=$backend_pid and objid=820260804")" = 1
history_count=$(psql -X -qAt -d "$DB_NAME" -c 'select count(*) from schema_history')
test "$history_count" -ge "$A_READY_HISTORY_COUNT"
printf 'A_READY=1 client_pid=%s backend_pid=%s lease_key=%s current_version=%s history_count=%s rows_validated=%s\n' "$client_pid" "$backend_pid" "$lease_key" "$current_version" "$history_count" "$rows_validated"
