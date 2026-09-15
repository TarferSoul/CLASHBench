#!/bin/bash
set -euo pipefail

DB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$DB_ROOT/fixture.env"

pg_bin() {
  local name=$1
  local path
  path=$(find /usr/lib/postgresql -mindepth 3 -maxdepth 3 -type f -name "$name" 2>/dev/null | sort -V | tail -n 1)
  [ -n "$path" ]
  printf '%s\n' "$path"
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
  apt-get install -y -qq --no-install-recommends \
    postgresql-14 postgresql-client-14 python3-psycopg2
  if [ "$policy_created" = 1 ]; then
    rm -f /usr/sbin/policy-rc.d
  fi
}

create_runtime_users() {
  getent passwd postgres >/dev/null
  if ! getent group "$SERVICE_USER" >/dev/null; then
    groupadd --gid "$SERVICE_GID" "$SERVICE_USER"
  fi
  if ! getent passwd "$SERVICE_USER" >/dev/null; then
    useradd --uid "$SERVICE_UID" --gid "$SERVICE_GID" --home-dir "$SERVICE_ROOT" \
      --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
  if ! getent group "$AGENT_USER" >/dev/null; then
    groupadd --gid "$AGENT_GID" "$AGENT_USER"
  fi
  if ! getent passwd "$AGENT_USER" >/dev/null; then
    useradd --uid "$AGENT_UID" --gid "$AGENT_GID" --create-home --shell /bin/bash "$AGENT_USER"
  fi
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
    --encoding=UTF8 --auth-local=trust --auth-host=reject > "$PG_LOG_ROOT/initdb.log" 2>&1
  cat >> "$PG_DATA_ROOT/postgresql.conf" <<EOF
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
  runuser -u postgres -- "$pg_ctl" --pgdata="$PG_DATA_ROOT" --log="$PG_LOG" \
    --options="-c config_file=$PG_DATA_ROOT/postgresql.conf" start >/dev/null
  for _ in $(seq 1 120); do
    if pg_isready --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
        >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  tail -100 "$PG_LOG" >&2 || true
  return 1
}

bootstrap_release_catalog() {
  psql_root --command="CREATE ROLE $A_DB_USER LOGIN"
  psql_root --command="CREATE ROLE $B_DB_USER LOGIN"
  psql_root --command="CREATE DATABASE $PG_DATABASE OWNER $A_DB_USER"
  psql_root --file="$DB_ROOT/db/init.sql"
}

install_release_service() {
  install -d -o root -g root -m 755 "$SERVICE_INSTALL_ROOT/bin"
  install -o root -g root -m 755 "$DB_ROOT/a/release_catalog_service.py" "$SERVICE_APP"
  install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 755 \
    "$SERVICE_ROOT" "$SERVICE_RUN_ROOT" "$SERVICE_STATE_DIR"
}

stop_postgres() {
  local pg_ctl
  if [ -d "$PG_DATA_ROOT" ]; then
    pg_ctl=$(pg_bin pg_ctl)
    runuser -u postgres -- "$pg_ctl" --pgdata="$PG_DATA_ROOT" stop -m fast >/dev/null 2>&1 || true
  fi
}
