#!/bin/bash
set -euo pipefail

DB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$DB_ROOT/fixture.env"

pg_bin() {
  local name=$1 path
  path=$(find /usr/lib/postgresql -mindepth 3 -maxdepth 3 -type f -name "$name" 2>/dev/null | sort -V | tail -n 1)
  [ -n "$path" ]
  printf '%s\n' "$path"
}

psql_root() {
  psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
    --no-password --set=ON_ERROR_STOP=1 "$@"
}

psql_pool_admin() {
  PGSSLMODE=disable psql --host="$POOL_HOST" --port="$POOL_PORT" \
    --username="$POOL_ADMIN_USER" --dbname=pgbouncer --no-password \
    --set=ON_ERROR_STOP=1 "$@"
}

ensure_database_packages() {
  if command -v psql >/dev/null 2>&1 \
      && command -v pgbouncer >/dev/null 2>&1 \
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
    postgresql-14 postgresql-client-14 pgbouncer python3-psycopg2
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
  install -d -o postgres -g postgres -m 750 "$PG_RUN_ROOT"
  install -d -o postgres -g postgres -m 750 "$PG_LOG_ROOT"
  runuser -u postgres -- "$initdb" --pgdata="$PG_DATA_ROOT" --no-locale \
    --encoding=UTF8 --auth-local=trust --auth-host=reject > "$PG_LOG_ROOT/initdb.log" 2>&1
  cat >> "$PG_DATA_ROOT/postgresql.conf" <<EOF
listen_addresses = ''
unix_socket_directories = '$PG_SOCKET'
unix_socket_permissions = 0770
max_connections = $PG_MAX_CONNECTIONS
shared_buffers = '96MB'
fsync = on
synchronous_commit = on
log_connections = on
log_disconnections = on
log_lock_waits = on
deadlock_timeout = '100ms'
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

bootstrap_feature_lab() {
  psql_root --command="CREATE ROLE $TARGET_DB_USER LOGIN"
  psql_root --command="CREATE ROLE $CONTROL_DB_USER LOGIN"
  psql_root --command="CREATE DATABASE $PG_DATABASE"
  psql_root --dbname="$PG_DATABASE" --file="$DB_ROOT/db/init.sql"
}

configure_pgbouncer() {
  rm -rf "$POOL_RUN_ROOT" "$POOL_LOG_ROOT" "$POOL_CONFIG_ROOT"
  install -d -o postgres -g postgres -m 750 "$POOL_RUN_ROOT" "$POOL_LOG_ROOT"
  install -d -o root -g postgres -m 750 "$POOL_CONFIG_ROOT"
  cat > "$POOL_CONFIG" <<EOF
[databases]
$PG_DATABASE = host=$PG_SOCKET port=5432 dbname=$PG_DATABASE pool_size=$POOL_SERVER_LIMIT

[pgbouncer]
listen_addr = $POOL_HOST
listen_port = $POOL_PORT
unix_socket_dir = $POOL_RUN_ROOT
auth_type = trust
auth_file = $POOL_AUTH_FILE
pool_mode = transaction
max_client_conn = 80
default_pool_size = $POOL_SERVER_LIMIT
min_pool_size = 0
reserve_pool_size = 0
query_wait_timeout = $POOL_QUERY_WAIT_TIMEOUT
server_idle_timeout = 60
server_lifetime = 3600
server_reset_query = DISCARD ALL
ignore_startup_parameters = extra_float_digits
admin_users = $POOL_ADMIN_USER
stats_users = $POOL_ADMIN_USER
pidfile = $POOL_PID_FILE
logfile = $POOL_LOG
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
EOF
  cat > "$POOL_AUTH_FILE" <<EOF
"$TARGET_DB_USER" ""
"$CONTROL_DB_USER" ""
"$POOL_ADMIN_USER" ""
EOF
  chown root:postgres "$POOL_CONFIG" "$POOL_AUTH_FILE"
  chmod 640 "$POOL_CONFIG" "$POOL_AUTH_FILE"
}

start_pgbouncer() {
  runuser -u postgres -- pgbouncer -d "$POOL_CONFIG"
  for _ in $(seq 1 120); do
    if psql_pool_admin --tuples-only --no-align --command "SHOW VERSION" \
        >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  tail -100 "$POOL_LOG" >&2 || true
  return 1
}

install_feature_service() {
  install -d -o root -g root -m 755 "$SERVICE_INSTALL_ROOT/bin" /etc/feature-parity-validator
  install -o root -g root -m 755 "$DB_ROOT/a/feature_parity_validator.py" "$SERVICE_APP"
  install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 750 "$SERVICE_ROOT"
  cat > "$SERVICE_CONFIG" <<EOF
{
  "host": "$POOL_HOST",
  "port": $POOL_PORT,
  "database": "$PG_DATABASE",
  "role": "$TARGET_DB_USER",
  "pool_size": $A_POOL_SIZE,
  "hold_seconds": $A_TX_HOLD_SECONDS,
  "service_token": "$SERVICE_TOKEN",
  "generation": "$SERVICE_GENERATION",
  "pool_generation": "$POOL_GENERATION",
  "model_version": "$MODEL_VERSION",
  "state_path": "$SERVICE_ROOT/service.json"
}
EOF
  chown "$AGENT_UID:$AGENT_GID" "$SERVICE_CONFIG"
  chmod 640 "$SERVICE_CONFIG"
}

stop_pgbouncer() {
  if [ -s "$POOL_PID_FILE" ]; then
    local pid
    pid=$(cat "$POOL_PID_FILE")
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || return 0
      sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

stop_postgres() {
  local pg_ctl
  pg_ctl=$(pg_bin pg_ctl 2>/dev/null || true)
  if [ -n "$pg_ctl" ] && [ -s "$PG_DATA_ROOT/postmaster.pid" ]; then
    runuser -u postgres -- "$pg_ctl" --pgdata="$PG_DATA_ROOT" --mode=fast stop \
      >/dev/null 2>&1 || true
  fi
}
