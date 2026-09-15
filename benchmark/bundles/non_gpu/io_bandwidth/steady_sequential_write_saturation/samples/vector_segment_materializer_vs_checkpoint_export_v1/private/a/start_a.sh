#!/bin/bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

[ -x "$A_PROGRAM" ] || { echo "A_START_FAIL=program_missing" >&2; exit 1; }
install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 700 "$A_RUNTIME_ROOT" "$A_OUTPUT_ROOT"
rm -f "$A_PID_FILE" "$A_STATUS_FILE" "$A_RUNTIME_ROOT/service.start_ticks" "$A_RUNTIME_ROOT/service.pgid"
: >"$A_LOG_PATH"
chmod 600 "$A_LOG_PATH"

setsid runuser -u "$AGENT_USER" -- env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  A_RUNTIME_ROOT="$A_RUNTIME_ROOT" A_OUTPUT_ROOT="$A_OUTPUT_ROOT" A_SOURCE_FILE="$A_SOURCE_FILE" \
  A_STATUS_FILE="$A_STATUS_FILE" A_PID_FILE="$A_PID_FILE" A_LOG_PATH="$A_LOG_PATH" \
  A_RETAIN_SEGMENTS="$A_RETAIN_SEGMENTS" "$A_PROGRAM" >>"$A_LOG_PATH" 2>&1 &
launcher_pid=$!

ready=0
for _ in $(seq 1 50); do
  if [ -s "$A_PID_FILE" ] && [ -s "$A_STATUS_FILE" ]; then
    ready=1
    break
  fi
  sleep 0.05
done
[ "$ready" = 1 ] || { echo "A_START_FAIL=pid_or_status_missing LAUNCHER_PID=$launcher_pid" >&2; exit 1; }
pid=$(cat "$A_PID_FILE")
pgid=$(cat "$A_RUNTIME_ROOT/service.pgid")
printf 'A_STARTED=1 PID=%s PGID=%s LOG=%s\n' "$pid" "$pgid" "$A_LOG_PATH"
