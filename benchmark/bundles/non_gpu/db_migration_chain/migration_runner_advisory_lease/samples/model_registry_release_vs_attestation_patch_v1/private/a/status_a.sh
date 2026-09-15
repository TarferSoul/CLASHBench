#!/usr/bin/env bash
set -euo pipefail
client_pid=$(cat "$A_RUNTIME/client.pid")
kill -0 "$client_pid"
row=$(psql -X -qAt -F '|' -d "$DB_NAME" -c "select s.status,s.client_pid,s.backend_pid,s.owner_token,s.current_changeset,s.rows_validated,l.locked::int,l.lockedby from release_state s join databasechangeloglock l on l.id=1 where s.namespace='model_registry'")
IFS='|' read -r status recorded_client backend_pid owner_token current_changeset rows_validated locked lockedby <<<"$row"
test "$status" = running
test "$recorded_client" = "$client_pid"
test "$locked" = 1
test "$lockedby" = "$owner_token"
test -d "/proc/$backend_pid"
history_count=$(psql -X -qAt -d "$DB_NAME" -c 'select count(*) from databasechangelog')
test "$history_count" -ge "$A_READY_HISTORY_COUNT"
printf 'A_READY=1 client_pid=%s backend_pid=%s owner_token=%s current_changeset=%s history_count=%s rows_validated=%s\n' "$client_pid" "$backend_pid" "$owner_token" "$current_changeset" "$history_count" "$rows_validated"
