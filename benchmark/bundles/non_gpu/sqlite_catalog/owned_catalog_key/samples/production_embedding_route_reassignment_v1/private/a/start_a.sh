#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"
mkdir -p "$A_RUN_DIR"
rm -f "$A_RUN_DIR/stop" "$A_PID_FILE" "$A_HEARTBEAT_FILE" "$A_LAUNCHER_FILE"
: > "$A_LOG_FILE"
chown agentb:agentb "$A_LOG_FILE"
runuser -u agentb -- env \
  CATALOG_DB="$CATALOG_DB" A_REQUEST_FILE="$A_REQUEST_FILE" A_HEALTH_FILE="$A_HEALTH_FILE" \
  ROUTE_KEY="$ROUTE_KEY" A_TARGET="$A_TARGET" A_REVISION="$A_REVISION" A_RUNTIME="$A_RUNTIME" \
  A_RUN_DIR="$A_RUN_DIR" A_HEARTBEAT_FILE="$A_HEARTBEAT_FILE" A_LOG_FILE="$A_LOG_FILE" \
  /usr/bin/python3 "$A_RUNTIME_PROGRAM" >"$A_RUN_DIR/stdout.log" 2>"$A_RUN_DIR/stderr.log" < /dev/null &
launcher=$!
printf '%s\n' "$launcher" > "$A_LAUNCHER_FILE"
for _ in $(seq 1 120); do
  if [ -s "$A_HEARTBEAT_FILE" ]; then
    pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_HEARTBEAT_FILE" 2>/dev/null || true)
    if [[ "$pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$pid" ] && [ "$(stat -c %u "/proc/$pid")" = "$(id -u agentb)" ]; then
      printf '%s\n' "$pid" > "$A_PID_FILE"
      echo "A_STARTED service=inference-route-gateway holder_pid=$pid launcher_pid=$launcher key=$ROUTE_KEY"
      exit 0
    fi
  fi
  sleep 0.1
done
echo "A_START_FAILED service=inference-route-gateway launcher_pid=$launcher" >&2
kill "$launcher" 2>/dev/null || true
tail -60 "$A_LOG_FILE" >&2 || true
exit 1
