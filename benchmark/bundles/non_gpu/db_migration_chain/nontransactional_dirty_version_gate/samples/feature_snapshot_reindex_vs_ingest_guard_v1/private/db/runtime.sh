#!/usr/bin/env bash
set -euo pipefail
DB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$DB_ROOT/fixture.env"

pg_bin() {
  local path
  path=$(find /usr/lib/postgresql -mindepth 3 -maxdepth 3 -type f -name "$1" 2>/dev/null | sort -V | tail -n 1)
  [ -n "$path" ]
  printf '%s\n' "$path"
}
psql_root() {
  psql --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_SUPERUSER" \
    --dbname=postgres --no-password --set=ON_ERROR_STOP=1 "$@"
}
ensure_postgres_packages() {
  if command -v psql >/dev/null 2>&1 && \
     find /usr/lib/postgresql -type f -name initdb -print -quit 2>/dev/null | grep -q . && \
     /usr/bin/python3 -c 'import psycopg2' >/dev/null 2>&1; then return 0; fi
  export DEBIAN_FRONTEND=noninteractive
  local created=0
  if [ ! -e /usr/sbin/policy-rc.d ]; then
    printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
    chmod 755 /usr/sbin/policy-rc.d
    created=1
  fi
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends postgresql postgresql-client python3-psycopg2
  [ "$created" = 0 ] || rm -f /usr/sbin/policy-rc.d
}
start_postgres() {
  local initdb pg_ctl agent_uid agent_gid
  initdb=$(pg_bin initdb); pg_ctl=$(pg_bin pg_ctl)
  agent_uid=$(id -u "$AGENT_USER"); agent_gid=$(id -g "$AGENT_USER")
  rm -rf "$PG_DATA_ROOT" "$PG_RUN_ROOT" "$PG_LOG_ROOT"
  install -d -o "$agent_uid" -g "$agent_gid" -m 700 "$PG_DATA_ROOT"
  install -d -o "$agent_uid" -g "$agent_gid" -m 755 "$PG_RUN_ROOT"
  install -d -o "$agent_uid" -g "$agent_gid" -m 750 "$PG_LOG_ROOT"
  runuser -u "$AGENT_USER" -- "$initdb" --pgdata="$PG_DATA_ROOT" --username="$PG_SUPERUSER" \
    --no-locale --encoding=UTF8 --auth-local=trust --auth-host=reject >"$PG_LOG_ROOT/initdb.log" 2>&1
  cat >>"$PG_DATA_ROOT/postgresql.conf" <<EOF
listen_addresses = ''
port = $PG_PORT
unix_socket_directories = '$PG_SOCKET'
unix_socket_permissions = 0777
max_connections = 40
shared_buffers = '128MB'
maintenance_work_mem = '192MB'
autovacuum = off
fsync = on
log_line_prefix = '%m [%p] %u@%d %a '
EOF
  chown "$agent_uid:$agent_gid" "$PG_DATA_ROOT/postgresql.conf"
  runuser -u "$AGENT_USER" -- "$pg_ctl" --pgdata="$PG_DATA_ROOT" --log="$PG_LOG" \
    --options="-c config_file=$PG_DATA_ROOT/postgresql.conf" start >/dev/null
  for _ in $(seq 1 150); do
    if pg_isready --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres >/dev/null 2>&1; then
      psql_root --command="CREATE ROLE $PG_ROLE LOGIN" >/dev/null
      return 0
    fi
    sleep 0.1
  done
  tail -100 "$PG_LOG" >&2 || true
  return 1
}
create_case_database() {
  local database=$1 rows=$2
  case "$database" in *[!a-z0-9_]*) echo "invalid database name: $database" >&2; return 2 ;; esac
  psql_root --command="DROP DATABASE IF EXISTS $database WITH (FORCE)" >/dev/null
  psql_root --command="CREATE DATABASE $database OWNER $PG_ROLE" >/dev/null
  psql --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_ROLE" --dbname="$database" \
    --no-password --set=ON_ERROR_STOP=1 --set=seed_rows="$rows" --set=expected_steps="$A_STEP_COUNT" \
    --file="$DB_ROOT/db/init.sql"
}
stop_postgres() {
  local pg_ctl
  pg_ctl=$(pg_bin pg_ctl 2>/dev/null || true)
  if [ -n "$pg_ctl" ] && [ -s "$PG_DATA_ROOT/postmaster.pid" ]; then
    runuser -u "$AGENT_USER" -- "$pg_ctl" --pgdata="$PG_DATA_ROOT" --mode=fast stop >/dev/null 2>&1 || true
  fi
}
