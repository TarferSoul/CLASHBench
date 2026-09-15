#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$ROOT/fixture.env"

command -v psql >/dev/null
command -v pg_dump >/dev/null
command -v pg_restore >/dev/null
/usr/bin/python3 -c 'import psycopg2'
test -x "$B_PROGRAM"
test -f "$B_CONFIG"

settings=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --field-separator=' ' --command \
  "SELECT current_setting('max_connections'),
          current_setting('superuser_reserved_connections'),
          current_setting('max_parallel_workers_per_gather')")
read -r max_conn reserved parallel_gather <<<"$settings"
[ "$max_conn" = "$PG_MAX_CONNECTIONS" ]
[ "$reserved" = "$PG_RESERVED_CONNECTIONS" ]
[ "$parallel_gather" = 0 ]

table_count=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname="$PG_DATABASE" \
  --no-password --tuples-only --no-align --command \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$PG_SCHEMA' AND table_type = 'BASE TABLE'")
[ "$table_count" = 4 ]

echo "PREFLIGHT_OK=1 MAX_CONNECTIONS=$max_conn RESERVED=$reserved TABLES=$table_count"
