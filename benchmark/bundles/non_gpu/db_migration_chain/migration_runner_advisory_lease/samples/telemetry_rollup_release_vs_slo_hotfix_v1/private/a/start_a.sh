#!/usr/bin/env bash
set -euo pipefail
rm -f "$A_RUNTIME/client.pid" "$A_RUNTIME/release.stdout" "$A_RUNTIME/release.stderr"
step_sleep=${A_STEP_SLEEP:-$A_STEP_SLEEP_DEFAULT}
runuser -u "$AGENT_USER" -- env PGHOST="$PGHOST" PGPORT="$PGPORT" PGUSER="$PGUSER" DB_NAME="$DB_NAME" \
  A_RUNTIME="$A_RUNTIME" STEP_SLEEP="$step_sleep" bash -c '
    printf "%s\n" "$$" >"$A_RUNTIME/client.pid"
    exec psql -X -q -v ON_ERROR_STOP=1 -v client_pid="$$" -v step_sleep="$STEP_SLEEP" -d "$DB_NAME" -f "$A_RUNTIME/release.sql"
  ' >"$A_RUNTIME/release.stdout" 2>"$A_RUNTIME/release.stderr" &
printf '%s\n' "$!" >"$A_RUNTIME/launcher.pid"
for _ in $(seq 1 50); do
  test -s "$A_RUNTIME/client.pid" && break
  sleep 0.05
done
test -s "$A_RUNTIME/client.pid"
printf 'A_START_OK=1 client_pid=%s step_sleep=%s\n' "$(cat "$A_RUNTIME/client.pid")" "$step_sleep"
