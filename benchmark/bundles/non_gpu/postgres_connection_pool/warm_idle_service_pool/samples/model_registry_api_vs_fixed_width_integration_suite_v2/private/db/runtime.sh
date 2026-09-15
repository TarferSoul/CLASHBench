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

java_classpath() {
  /usr/bin/python3 - <<'PY'
import pathlib

jars = []
root = pathlib.Path("/usr/share/java")

def require_any(*patterns):
    matches = []
    for pattern in patterns:
        matches.extend(root.glob(pattern))
    matches = sorted(set(matches))
    if not matches:
        raise SystemExit("missing_java_dependency")
    jars.append(str(matches[-1]))

def add_optional(*patterns):
    matches = []
    for pattern in patterns:
        matches.extend(root.glob(pattern))
    matches = sorted(set(matches))
    if matches:
        jars.append(str(matches[-1]))

require_any("*HikariCP*.jar", "*hikaricp*.jar")
require_any("postgresql*.jar")
require_any("slf4j-api*.jar")
add_optional("slf4j-simple*.jar", "slf4j-nop*.jar")
print(":".join(jars))
PY
}

psql_root() {
  psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" \
    --dbname=postgres --no-password --set=ON_ERROR_STOP=1 "$@"
}

ensure_runtime_packages() {
  if command -v psql >/dev/null 2>&1 \
      && command -v pg_isready >/dev/null 2>&1 \
      && find /usr/lib/postgresql -type f -name initdb -print -quit 2>/dev/null | grep -q . \
      && command -v javac >/dev/null 2>&1 \
      && java_classpath >/dev/null 2>&1 \
      && /usr/bin/python3 -c 'import psycopg2, pytest, xdist' >/dev/null 2>&1; then
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
    postgresql-14 postgresql-client-14 python3-psycopg2 python3-pytest \
    python3-pytest-xdist default-jdk-headless libhikaricp-java \
    libpostgresql-jdbc-java libslf4j-java >/tmp/model_registry_apt.log 2>&1 || {
      apt-get install -y -qq --no-install-recommends \
        postgresql postgresql-client python3-psycopg2 python3-pytest \
        python3-pytest-xdist default-jdk-headless libhikaricp-java \
        libpostgresql-jdbc-java libslf4j-java >/tmp/model_registry_apt_retry.log 2>&1
    }
  if [ "$policy_created" = 1 ]; then
    rm -f /usr/sbin/policy-rc.d
  fi
  /usr/bin/python3 -c 'import psycopg2, pytest, xdist'
  command -v javac >/dev/null
  java_classpath >/dev/null
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
    --encoding=UTF8 --auth-local=trust --auth-host=trust > "$PG_LOG_ROOT/initdb.log" 2>&1
  cat >> "$PG_DATA_ROOT/postgresql.conf" <<EOF
listen_addresses = '$PG_HOST'
port = $PG_PORT
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
    if pg_isready --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" \
        --dbname=postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  tail -100 "$PG_LOG" >&2 || true
  return 1
}

bootstrap_model_registry() {
  psql_root --command="CREATE ROLE $A_DB_USER LOGIN"
  psql_root --command="CREATE ROLE $B_DB_USER LOGIN"
  psql_root --command="CREATE DATABASE $PG_DATABASE OWNER $A_DB_USER"
  psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" \
    --dbname="$PG_DATABASE" --no-password --set=ON_ERROR_STOP=1 \
    --file="$DB_ROOT/db/init.sql"
}

compile_model_registry_service() {
  install -d -o root -g root -m 755 "$SERVICE_INSTALL_ROOT/src" "$SERVICE_CLASSES" \
    /etc/model-registry-api
  install -o root -g root -m 644 "$DB_ROOT/a/ModelRegistryService.java" "$SERVICE_SOURCE"
  javac -cp "$(java_classpath)" -d "$SERVICE_CLASSES" "$SERVICE_SOURCE"
  install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 755 "$SERVICE_ROOT"
  cat > "$SERVICE_CONFIG" <<EOF
database=$PG_DATABASE
db_user=$A_DB_USER
db_host=$PG_HOST
db_port=$PG_PORT
pool_size=$A_POOL_SIZE
pool_name=$SERVICE_POOL_NAME
service_token=$SERVICE_TOKEN
generation=$SERVICE_GENERATION
state_path=$SERVICE_ROOT/service.json
stop_path=$SERVICE_ROOT/stop.request
http_host=$SERVICE_HOST
http_port=$SERVICE_PORT
EOF
  chmod 644 "$SERVICE_CONFIG"
}

stop_postgres() {
  local pg_ctl
  pg_ctl=$(pg_bin pg_ctl 2>/dev/null || true)
  if [ -n "$pg_ctl" ] && [ -s "$PG_DATA_ROOT/postmaster.pid" ]; then
    runuser -u postgres -- "$pg_ctl" --pgdata="$PG_DATA_ROOT" --mode=fast stop \
      >/dev/null 2>&1 || true
  fi
}
