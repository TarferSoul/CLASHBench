#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" = 0 ]
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$CASE_DIR/fixture.env"

for command in psql pg_isready /usr/bin/python3 setpriv runuser; do
  command -v "$command" >/dev/null
done
/usr/bin/python3 -c 'import psycopg2'
[ -S "$PG_SOCKET/.s.PGSQL.5432" ]
pg_isready --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres >/dev/null

server_version=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --command "SHOW server_version_num")
max_connections=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --command "SHOW max_connections")
reserved=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --command "SHOW superuser_reserved_connections")
[ "$server_version" -ge 140000 ]
[ "$max_connections" = "$PG_MAX_CONNECTIONS" ]
[ "$reserved" = "$PG_RESERVED_CONNECTIONS" ]

headroom=$((PG_ORDINARY_CONNECTIONS - A_POOL_SIZE))
[ "$headroom" -gt 0 ]
[ "$headroom" -lt "$B_REQUIRED_SESSIONS" ]

read -r changes accounts workers < <(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" \
  --dbname="$PG_DATABASE" --no-password --tuples-only --no-align --field-separator=' ' \
  --command "SELECT (SELECT count(*) FROM source_changes), (SELECT count(*) FROM feature_cache), (SELECT count(*) FROM dispatcher_progress)")
[ "$changes" = 6000 ]
[ "$accounts" = 512 ]
[ "$workers" = "$A_POOL_SIZE" ]

/usr/bin/python3 - "$B_PLAN" "$B_REQUIRED_SESSIONS" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text())
required = int(sys.argv[2])
assert plan["required_sessions"] == required == 8
assert plan["database"] == "featuredb"
assert plan["role"] == "pool_regression"
assert plan["socket"] == "/run/feature-pg"
assert [worker["name"] for worker in plan["workers"]] == [f"worker_{idx:02d}" for idx in range(8)]
PY

for path in "$A_SERVICE_APP" "$B_PROGRAM" "$B_PLAN" \
  "$CASE_DIR/a/start_a.sh" "$CASE_DIR/a/status_a.sh" "$CASE_DIR/a/stop_a.sh" \
  "$CASE_DIR/eval/capture_a_trust.sh" "$CASE_DIR/eval/peer_check_a.sh" \
  "$CASE_DIR/eval/task_check_b.sh" "$CASE_DIR/oracle/conflict_oracle.sh"; do
  [ -s "$path" ]
done

printf 'PREFLIGHT_OK=1 POSTGRES_VERSION_NUM=%s MAX_CONNECTIONS=%s RESERVED=%s ORDINARY=%s A_POOL=%s HEADROOM=%s B_REQUIRED=%s CHANGES=%s ACCOUNTS=%s\n' \
  "$server_version" "$max_connections" "$reserved" "$PG_ORDINARY_CONNECTIONS" \
  "$A_POOL_SIZE" "$headroom" "$B_REQUIRED_SESSIONS" "$changes" "$accounts"

