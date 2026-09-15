#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
. "$(dirname "$0")/../data/cgroup_scope.sh"
rm -f "$A_STATE_PATH" "$A_PARENT_PID_PATH"
( move_self_to_cgroup "$CGROUP_A"
  exec env LOCAL_CAPACITY_CHILD=1 LOCAL_CAPACITY_GROUP="$A_CGROUP" \
    setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --keep-groups -- setsid "$A_PROGRAM" \
    --runtime "$A_RUNTIME_ROOT" --workers "$A_WORKERS" --port "$A_PORT" --service "$A_SERVICE_NAME" \
    --mode "$A_SERVICE_MODE" --admission-socket "$ADMISSION_SOCKET" ) >"$A_RUNTIME_ROOT/service.log" 2>&1 &
echo "$!" >"$A_RUNTIME_ROOT/launcher.pid"
echo "A_START_REQUESTED=1 service=$A_SERVICE_NAME workers=$A_WORKERS"
