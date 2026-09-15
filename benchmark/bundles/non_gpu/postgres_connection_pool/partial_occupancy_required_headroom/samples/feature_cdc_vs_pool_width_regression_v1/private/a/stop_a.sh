#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$CASE_DIR/fixture.env"

pid=""
if [ -s "$A_SERVICE_ROOT/supervisor.pid" ]; then
  pid=$(cat "$A_SERVICE_ROOT/supervisor.pid")
fi
if [ -d "$A_SERVICE_ROOT" ]; then
  : >"$A_SERVICE_ROOT/stop.request"
  chown "$A_SERVICE_UID:$A_SERVICE_GID" "$A_SERVICE_ROOT/stop.request" 2>/dev/null || true
fi

if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  for _ in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
  fi
fi

remaining=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname="$PG_DATABASE" \
  --no-password --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_stat_activity WHERE usename = '$A_DB_USER' AND application_name LIKE 'feature-cache-dispatcher/%'" \
  2>/dev/null || printf 'unknown')
printf 'A_STOPPED=1 PID=%s REMAINING_BACKENDS=%s\n' "${pid:-none}" "$remaining"

