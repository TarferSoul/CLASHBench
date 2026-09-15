#!/bin/bash
set -euo pipefail

[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"
. "$ROOT/db/runtime.sh"

command -v psql >/dev/null
command -v pg_isready >/dev/null
command -v java >/dev/null
command -v javac >/dev/null
java_classpath >/dev/null
/usr/bin/python3 -c 'import psycopg2, pytest, xdist'
[ -d "$SERVICE_CLASSES" ]
[ -f "$SERVICE_CONFIG" ]
[ -f "$B_PLAN" ]
[ -f "$B_SUITE/run_release_db_validation.py" ]
[ -f "$B_SUITE/tests/test_release_database_contract.py" ]

schema_count=$(psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" \
  --dbname="$PG_DATABASE" --no-password --tuples-only --no-align --command \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'registry'")
[ "$schema_count" = "$EXPECTED_TABLE_COUNT" ]

echo "PREFLIGHT_OK=1 DB=$PG_DATABASE TABLES=$schema_count A_POOL_SIZE=$A_POOL_SIZE B_WORKERS=$B_PYTEST_WORKERS"
