#!/bin/bash

start_a() {
  . "$CASE_PRIVATE_ROOT/fixture.env"
  rm -f "$A_STATE_ROOT/stop.request"
  rm -rf "$A_STATE_ROOT/progress"
  install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 755 "$A_STATE_ROOT" "$A_STATE_ROOT/progress"
  setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --init-groups \
    env HOME="/home/$SERVICE_USER" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" \
    PATH=/usr/local/bin:/usr/bin:/bin PYTHONUNBUFFERED=1 \
    python3 "$A_TOOL" --migrations "$A_SOURCE_ROOT" --state "$A_STATE_ROOT" \
      --workers "$A_WORKERS" --cycle-pause "$A_CYCLE_PAUSE_SECONDS" \
      > "$A_STATE_ROOT/service.log" 2>&1 &
  A_PID=$!
  export A_PID
  local deadline=$((SECONDS + A_READY_TIMEOUT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -s "$A_STATE_ROOT/roster.json" ] && [ -s "$A_STATE_ROOT/health.json" ] && kill -0 "$A_PID" 2>/dev/null; then
      printf 'A_START_OK=1 pid=%s\n' "$A_PID"
      return 0
    fi
    if ! kill -0 "$A_PID" 2>/dev/null; then
      echo "A_START_OK=0 reason=supervisor_exited" >&2
      return 1
    fi
    sleep 0.05
  done
  echo "A_START_OK=0 reason=readiness_timeout" >&2
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "start_a.sh must be sourced by the root lifecycle shell" >&2
  exit 2
fi
