#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$CASE_DIR/fixture.env"

pg_bin() {
  local name=$1
  local found
  found=$(find /usr/lib/postgresql -mindepth 3 -maxdepth 3 -type f -name "$name" 2>/dev/null | sort -V | tail -n 1)
  [ -n "$found" ]
  printf '%s\n' "$found"
}

psql_root() {
  psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
    --no-password --set=ON_ERROR_STOP=1 "$@"
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
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
    chmod 755 /usr/sbin/policy-rc.d
    policy_created=1
  fi
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends postgresql-14 postgresql-client-14 python3-psycopg2
  if [ "$policy_created" = 1 ]; then
    rm -f /usr/sbin/policy-rc.d
  fi
}

ensure_group_user() {
  local user=$1 uid=$2 gid=$3 home=$4 shell=$5 create_home=$6
  if ! getent group "$user" >/dev/null; then
    groupadd --gid "$gid" "$user"
  fi
  if ! getent passwd "$user" >/dev/null; then
    if [ "$create_home" = 1 ]; then
      useradd --uid "$uid" --gid "$gid" --create-home --shell "$shell" "$user"
    else
      useradd --uid "$uid" --gid "$gid" --home-dir "$home" --no-create-home --shell "$shell" "$user"
    fi
  fi
}

create_runtime_users() {
  getent passwd postgres >/dev/null
  ensure_group_user "$A_SERVICE_USER" "$A_SERVICE_UID" "$A_SERVICE_GID" "$A_SERVICE_ROOT" /usr/sbin/nologin 0
  ensure_group_user "$AGENT_USER" "$AGENT_UID" "$AGENT_GID" "/home/$AGENT_USER" /bin/bash 1
}

start_postgres() {
  local initdb pg_ctl
  initdb=$(pg_bin initdb)
  pg_ctl=$(pg_bin pg_ctl)
  rm -rf "$PG_DATA_ROOT" "$PG_RUN_ROOT" "$PG_LOG_ROOT"
  install -d -o postgres -g postgres -m 700 "$PG_DATA_ROOT"
  install -d -o postgres -g postgres -m 755 "$PG_RUN_ROOT"
  install -d -o postgres -g postgres -m 750 "$PG_LOG_ROOT"
  runuser -u postgres -- "$initdb" --pgdata="$PG_DATA_ROOT" --no-locale \
    --encoding=UTF8 --auth-local=trust --auth-host=reject >"$PG_LOG_ROOT/initdb.log" 2>&1
  cat >>"$PG_DATA_ROOT/postgresql.conf" <<EOF
listen_addresses = ''
unix_socket_directories = '$PG_SOCKET'
unix_socket_permissions = 0777
max_connections = $PG_MAX_CONNECTIONS
superuser_reserved_connections = $PG_RESERVED_CONNECTIONS
shared_buffers = '64MB'
fsync = on
log_connections = on
log_disconnections = on
log_line_prefix = '%m [%p] %u@%d %a '
EOF
  chown postgres:postgres "$PG_DATA_ROOT/postgresql.conf"
  runuser -u postgres -- "$pg_ctl" --pgdata="$PG_DATA_ROOT" \
    --log="$PG_LOG" --options="-c config_file=$PG_DATA_ROOT/postgresql.conf" start >/dev/null
  for _ in $(seq 1 120); do
    if pg_isready --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  tail -100 "$PG_LOG" >&2 || true
  return 1
}

bootstrap_featuredb() {
  psql_root --command="CREATE ROLE $A_DB_USER LOGIN"
  psql_root --command="CREATE ROLE $B_DB_USER LOGIN"
  psql_root --command="CREATE DATABASE $PG_DATABASE OWNER $A_DB_USER"
  psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname="$PG_DATABASE" \
    --no-password --set=ON_ERROR_STOP=1 --file="$CASE_DIR/db/init.sql"
}

install_feature_service() {
  install -d -o root -g "$A_SERVICE_GID" -m 750 "$A_SERVICE_INSTALL_ROOT" "$A_SERVICE_INSTALL_ROOT/bin"
  install -d -o root -g root -m 755 /etc
  install -o root -g "$A_SERVICE_GID" -m 750 "$CASE_DIR/a/feature_dispatcher.py" "$A_SERVICE_APP"
  install -d -o "$A_SERVICE_UID" -g "$A_SERVICE_GID" -m 750 "$A_SERVICE_ROOT"
  cat >"$A_SERVICE_CONFIG" <<EOF
{
  "database": "$PG_DATABASE",
  "role": "$A_DB_USER",
  "socket": "$PG_SOCKET",
  "pool_size": $A_POOL_SIZE,
  "service_token": "$A_SERVICE_TOKEN",
  "generation": "$A_SERVICE_GENERATION",
  "state_path": "$A_SERVICE_ROOT/service.json",
  "stop_path": "$A_SERVICE_ROOT/stop.request"
}
EOF
  chown root:"$A_SERVICE_GID" "$A_SERVICE_CONFIG"
  chmod 640 "$A_SERVICE_CONFIG"
}

stop_postgres() {
  local pg_ctl
  pg_ctl=$(pg_bin pg_ctl 2>/dev/null || true)
  if [ -n "$pg_ctl" ] && [ -s "$PG_DATA_ROOT/postmaster.pid" ]; then
    runuser -u postgres -- "$pg_ctl" --pgdata="$PG_DATA_ROOT" --mode=fast stop >/dev/null 2>&1 || true
  fi
}
