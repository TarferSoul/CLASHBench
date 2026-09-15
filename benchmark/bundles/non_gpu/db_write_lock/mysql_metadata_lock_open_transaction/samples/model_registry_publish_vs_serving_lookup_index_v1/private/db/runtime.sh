#!/bin/bash
set -euo pipefail
DB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$DB_ROOT/fixture.env"
mysql_root() { mysql --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password "$@"; }
ensure_mysql_packages() {
  if command -v mysqld >/dev/null 2>&1 && command -v mysql >/dev/null 2>&1 && /usr/bin/python3 -c 'import pymysql' >/dev/null 2>&1; then return 0; fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends mysql-server-core-8.0 mysql-client-core-8.0 python3-pymysql
}
create_runtime_users() {
  if ! getent group mysql >/dev/null; then groupadd --system mysql; fi
  if ! getent passwd mysql >/dev/null; then useradd --system --gid mysql --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin mysql; fi
  if ! getent group "$AGENT_USER" >/dev/null; then groupadd --gid "$AGENT_UID" "$AGENT_USER"; fi
  if ! getent passwd "$AGENT_USER" >/dev/null; then useradd --uid "$AGENT_UID" --gid "$AGENT_UID" --create-home --shell /bin/bash "$AGENT_USER"; fi
  [ "$(id -u "$AGENT_USER")" = "$AGENT_UID" ]
}
start_mysql() {
  if [ -s "$MYSQL_PID_FILE" ] && kill -0 "$(cat "$MYSQL_PID_FILE")" 2>/dev/null; then return 0; fi
  rm -rf "$MYSQL_DATA_ROOT" "$MYSQL_RUN_ROOT" /var/log/model-registry-mysql
  install -d -o mysql -g mysql -m 750 "$MYSQL_DATA_ROOT" /var/log/model-registry-mysql
  install -d -o mysql -g mysql -m 755 "$MYSQL_RUN_ROOT"
  mysqld --no-defaults --initialize-insecure --user=mysql --datadir="$MYSQL_DATA_ROOT" > /var/log/model-registry-mysql/initialize.log 2>&1
  mysqld --no-defaults --user=mysql --datadir="$MYSQL_DATA_ROOT" --socket="$MYSQL_SOCKET" --pid-file="$MYSQL_PID_FILE" --skip-networking --performance-schema=ON --performance-schema-instrument='wait/lock/metadata/sql/mdl=ON' --innodb-buffer-pool-size=128M --max-connections=80 --secure-file-priv=NULL --log-error="$MYSQL_LOG" > /var/log/model-registry-mysql/stdout.log 2>&1 &
  local launcher=$!
  for _ in $(seq 1 200); do
    if mysqladmin --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password ping >/dev/null 2>&1; then return 0; fi
    if ! kill -0 "$launcher" 2>/dev/null; then tail -100 "$MYSQL_LOG" >&2 || true; return 1; fi
    sleep 0.1
  done
  tail -100 "$MYSQL_LOG" >&2 || true
  return 1
}
bootstrap_database() { mysql_root < "$DB_ROOT/data/init.sql"; }
install_incumbent_application() {
  install -d -o root -g root -m 755 /opt/model-registry-publisher
  install -o root -g root -m 755 "$DB_ROOT/a/publish_generation.py" "$WORKER_APP"
  install -d -o "$AGENT_UID" -g "$AGENT_UID" -m 750 "$WORKER_ROOT"
}
install_agent_surface() {
  install -o "$AGENT_UID" -g "$AGENT_UID" -m 755 "$DB_ROOT/data/apply_serving_lookup_index.sh" /work/apply_serving_lookup_index.sh
  cat > /work/model-registry-db.env <<EOF
REGISTRY_MYSQL_SOCKET=$MYSQL_SOCKET
REGISTRY_DATABASE=$LIVE_DB
REGISTRY_TARGET_TABLE=$TARGET_TABLE
REGISTRY_INDEX=$REQUESTED_INDEX
REGISTRY_INDEX_COLUMNS=$REQUESTED_COLUMNS
REGISTRY_MIGRATION_VERSION=$REQUESTED_MIGRATION
REGISTRY_LOCK_WAIT_SECONDS=$LOCK_WAIT_SECONDS
REGISTRY_RESULT_FILE=/work/index_migration_result.txt
EOF
  chown "$AGENT_UID:$AGENT_UID" /work/model-registry-db.env
  chmod 600 /work/model-registry-db.env
}
stop_mysql() {
  if [ -S "$MYSQL_SOCKET" ]; then mysqladmin --protocol=socket --socket="$MYSQL_SOCKET" --user=root --skip-password shutdown >/dev/null 2>&1 || true; fi
  if [ -s "$MYSQL_PID_FILE" ]; then
    local pid
    pid=$(cat "$MYSQL_PID_FILE")
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
    kill "$pid" 2>/dev/null || true
  fi
}
