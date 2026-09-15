#!/usr/bin/env bash
set -euo pipefail

DB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$DB_ROOT/fixture.env"

pg_bin() {
  local name=$1 path
  path=$(find /usr/lib/postgresql -mindepth 3 -maxdepth 3 -type f -name "$name" 2>/dev/null | sort -V | tail -n 1)
  [ -n "$path" ]
  printf '%s\n' "$path"
}

psql_admin() {
  runuser -u "$AGENT_USER" -- psql --host="$PG_SOCKET" --port="$PG_PORT" \
    --username="$PG_SUPERUSER" --no-password --no-psqlrc --set=ON_ERROR_STOP=1 "$@"
}

ensure_postgres_packages() {
  if command -v psql >/dev/null 2>&1 \
      && find /usr/lib/postgresql -type f -name initdb -print -quit 2>/dev/null | grep -q . \
      && /usr/bin/python3 -c 'import psycopg2' >/dev/null 2>&1; then
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  local policy_created=0
  if [ ! -e /usr/sbin/policy-rc.d ]; then
    printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
    chmod 755 /usr/sbin/policy-rc.d
    policy_created=1
  fi
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    postgresql-14 postgresql-client-14 postgresql-contrib-14 python3-psycopg2
  if [ "$policy_created" = 1 ]; then rm -f /usr/sbin/policy-rc.d; fi
}

start_postgres() {
  local initdb pg_ctl
  initdb=$(pg_bin initdb)
  pg_ctl=$(pg_bin pg_ctl)
  rm -rf "$PG_DATA_ROOT" "$PG_RUN_ROOT" "$PG_LOG_ROOT"
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0700 "$PG_DATA_ROOT"
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 "$PG_RUN_ROOT"
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0750 "$PG_LOG_ROOT"
  runuser -u "$AGENT_USER" -- "$initdb" --pgdata="$PG_DATA_ROOT" --username="$PG_SUPERUSER" \
    --no-locale --encoding=UTF8 --auth-local=trust --auth-host=reject >"$PG_LOG_ROOT/initdb.log" 2>&1
  cat >>"$PG_DATA_ROOT/postgresql.conf" <<EOF
listen_addresses = ''
port = $PG_PORT
unix_socket_directories = '$PG_SOCKET'
unix_socket_permissions = 0777
max_connections = 32
shared_buffers = '64MB'
fsync = on
log_lock_waits = on
deadlock_timeout = '100ms'
log_line_prefix = '%m [%p] %u@%d %a '
EOF
  printf 'local all all trust\n' >"$PG_DATA_ROOT/pg_hba.conf"
  chown "$AGENT_USER:$AGENT_USER" "$PG_DATA_ROOT/postgresql.conf" "$PG_DATA_ROOT/pg_hba.conf"
  runuser -u "$AGENT_USER" -- "$pg_ctl" --pgdata="$PG_DATA_ROOT" --log="$PG_LOG" start >/dev/null
  for _ in $(seq 1 120); do
    if runuser -u "$AGENT_USER" -- pg_isready --host="$PG_SOCKET" --port="$PG_PORT" \
        --username="$PG_SUPERUSER" --dbname=postgres >/dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  tail -100 "$PG_LOG" >&2 || true
  return 1
}

bootstrap_database() {
  psql_admin --dbname=postgres --command="CREATE ROLE $A_DB_USER LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION"
  psql_admin --dbname=postgres --command="CREATE ROLE $B_DB_USER LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION"
  psql_admin --dbname=postgres --command="CREATE DATABASE $LIVE_DB OWNER $PG_SUPERUSER"
  psql_admin --dbname="$LIVE_DB" <"$DB_ROOT/db/init.sql"
}

install_incumbent() {
  install -d -o root -g root -m 0755 "$SERVICE_INSTALL_ROOT/bin"
  install -o root -g root -m 0755 "$DB_ROOT/a/feature_snapshot_closeout.py" "$SERVICE_APP"
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0750 "$SERVICE_ROOT"
}

stop_postgres() {
  local pg_ctl
  pg_ctl=$(pg_bin pg_ctl 2>/dev/null || true)
  if [ -n "$pg_ctl" ] && [ -s "$PG_DATA_ROOT/postmaster.pid" ]; then
    runuser -u "$AGENT_USER" -- "$pg_ctl" --pgdata="$PG_DATA_ROOT" --mode=fast stop >/dev/null 2>&1 || true
  fi
}
