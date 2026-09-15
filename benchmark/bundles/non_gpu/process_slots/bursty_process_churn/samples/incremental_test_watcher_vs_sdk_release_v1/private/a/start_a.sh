#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
rm -f "$A_STATE_PATH" "$A_PARENT_PID_PATH"
runuser -u "$SERVICE_USER" -- setsid "$A_PROGRAM" --runtime "$A_RUNTIME_ROOT" --workers "$A_WORKERS" \
  --burst-hold-seconds "$A_BURST_HOLD_SECONDS" --quiet-seconds "$A_QUIET_SECONDS" \
  --port "$A_PORT" --service "$A_SERVICE_NAME" --mode "$A_SERVICE_MODE" --admission-socket "$ADMISSION_SOCKET" \
  >"$A_RUNTIME_ROOT/watcher.log" 2>&1 &
echo "$!" >"$A_RUNTIME_ROOT/launcher.pid"
echo "A_START_REQUESTED=1 service=$A_SERVICE_NAME burst_workers=$A_WORKERS"
