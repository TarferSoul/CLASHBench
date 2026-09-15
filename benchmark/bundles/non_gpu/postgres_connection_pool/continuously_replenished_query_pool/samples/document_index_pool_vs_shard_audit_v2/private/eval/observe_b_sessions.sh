#!/bin/bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

OUTPUT=${1:?set output path}
install -o root -g root -m 600 /dev/null "$OUTPUT"
printf 'observed_epoch\tsession_count\tbackend_pids\tapplication_names\trole_count\tdatabase_count\n' > "$OUTPUT"

while :; do
  row=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
    --no-password --tuples-only --no-align --field-separator=$'\t' --command \
    "SELECT extract(epoch FROM clock_timestamp()),
            count(*),
            coalesce(string_agg(pid::text, ',' ORDER BY pid), ''),
            coalesce(string_agg(application_name, ',' ORDER BY application_name), ''),
            count(*) FILTER (WHERE usename = '$B_DB_USER'),
            count(*) FILTER (WHERE datname = '$PG_DATABASE')
     FROM pg_stat_activity
     WHERE application_name LIKE 'search-shard-audit/%'" 2>/dev/null) || row=""
  if [ -n "$row" ]; then
    printf '%s\n' "$row" >> "$OUTPUT"
  fi
  sleep 0.02
done
