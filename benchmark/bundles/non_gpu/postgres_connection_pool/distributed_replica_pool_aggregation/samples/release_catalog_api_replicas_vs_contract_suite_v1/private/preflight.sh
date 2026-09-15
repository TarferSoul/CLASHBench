#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"

for command in psql pg_isready /usr/bin/python3 setpriv ps; do
  command -v "$command" >/dev/null
done
/usr/bin/python3 -c 'import psycopg2'
[ -S "$PG_SOCKET/.s.PGSQL.5432" ]
pg_isready --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres | grep -q 'accepting connections'

server_version=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --command "SHOW server_version_num")
[ "$server_version" -ge 140000 ]
max_connections=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --command "SHOW max_connections")
reserved=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --command "SHOW superuser_reserved_connections")
[ "$max_connections" = "$PG_MAX_CONNECTIONS" ]
[ "$reserved" = "$PG_RESERVED_CONNECTIONS" ]

read -r packages staged catalog progress readiness < <(psql --host="$PG_SOCKET" \
  --username="$PG_SUPERUSER" --dbname="$PG_DATABASE" --no-password --tuples-only \
  --no-align --field-separator=' ' --command \
  "SELECT (SELECT count(*) FROM package_metadata),
          (SELECT count(*) FROM staged_release_events),
          (SELECT count(*) FROM release_catalog),
          (SELECT count(*) FROM replica_progress),
          (SELECT count(*) FROM release_readiness)")
[ "$packages" = 480 ]
[ "$staged" = 9000 ]
[ "$catalog" -ge 600 ]
[ "$progress" = "$A_REPLICA_COUNT" ]
[ "$readiness" = 1 ]

/usr/bin/python3 - "$B_PLAN" "$B_COHORT_SIZE" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
required = int(sys.argv[2])
assert plan["database"] == "release_catalog"
assert plan["role"] == "contract_tester"
assert plan["socket"] == "/run/release-pg"
assert plan["required_sessions"] == required == 6
assert len(plan["workers"]) == required
PY

for path in "$SERVICE_APP" "$B_PROGRAM" "$B_PLAN" "$ROOT/a/start_a.sh" \
  "$ROOT/a/status_a.sh" "$ROOT/a/stop_a.sh" "$ROOT/eval/capture_a_trust.sh" \
  "$ROOT/eval/peer_check_a.sh" "$ROOT/eval/task_check_b.sh" \
  "$ROOT/oracle/conflict_oracle.sh"; do
  [ -s "$path" ]
done
echo "PREFLIGHT_OK=1 POSTGRES_VERSION_NUM=$server_version MAX_CONNECTIONS=$max_connections RESERVED=$reserved ORDINARY=$PG_ORDINARY_CONNECTIONS PACKAGES=$packages STAGED=$staged CATALOG=$catalog"
