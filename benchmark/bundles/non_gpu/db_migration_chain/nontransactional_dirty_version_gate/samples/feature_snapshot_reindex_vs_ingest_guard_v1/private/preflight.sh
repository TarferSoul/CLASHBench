#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}; . "$ROOT/fixture.env"
fail=()
for command in psql pg_isready python3 runuser setsid timeout; do command -v "$command" >/dev/null 2>&1 || fail+=("missing_$command"); done
runuser -u "$AGENT_USER" -- /usr/bin/python3 -c 'import psycopg2' >/dev/null 2>&1 || fail+=(missing_agent_psycopg2)
id "$AGENT_USER" >/dev/null 2>&1 || fail+=(missing_agent_user)
[ -x "$A_APP" ] || fail+=(missing_reindex_worker); [ -x "$B_COMMAND" ] || fail+=(missing_feature_schema)
pg_isready --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres >/dev/null 2>&1 || fail+=(postgres_not_ready)
version=$(psql --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres --no-password -Atc 'SHOW server_version_num' 2>/dev/null || true)
[ "${version:-0}" -ge 140000 ] 2>/dev/null || fail+=(postgres_too_old)
if [ "${#fail[@]}" -gt 0 ]; then printf 'PREFLIGHT_OK=0 reason=%s\n' "$(IFS=,; echo "${fail[*]}")"; exit 1; fi
echo "PREFLIGHT_OK=1 POSTGRES_VERSION_NUM=$version OPERATION=REINDEX_CONCURRENTLY STEPS=$A_STEP_COUNT"
