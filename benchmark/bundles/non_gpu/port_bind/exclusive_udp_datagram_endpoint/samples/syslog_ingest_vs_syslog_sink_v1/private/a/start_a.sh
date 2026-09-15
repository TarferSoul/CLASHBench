#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}; . "$ROOT/fixture.env"
id "$AGENT_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$AGENT_USER"
rm -rf "$A_RUN_DIR"; mkdir -p "$A_RUN_DIR"
install -m 0750 -o "$AGENT_USER" -g "$AGENT_USER" "$ROOT/a/syslog_collector.py" "$A_RUN_DIR/syslog_collector.py"
chown "$AGENT_USER:$AGENT_USER" "$A_RUN_DIR"; chmod 0750 "$A_RUN_DIR"
runuser -u "$AGENT_USER" -- env A_HOST="$HOST" A_PORT="$PORT" A_RUN_DIR="$A_RUN_DIR" A_PID_FILE="$A_PID_FILE" A_READY_FILE="$A_READY_FILE" A_SERVICE_NAME="$A_SERVICE_NAME" A_INSTANCE="$A_INSTANCE" A_IDENTITY_TOKEN="$A_IDENTITY_TOKEN" setsid python3 "$A_RUN_DIR/syslog_collector.py" >"$A_RUN_DIR/service.log" 2>&1 < /dev/null &
launcher=$!
for _ in $(seq 1 80); do
  if [ -s "$A_READY_FILE" ] && bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    echo "A_STARTED service=$A_SERVICE_NAME pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_PID_FILE") port=$HOST:$PORT"; exit 0
  fi
  if ! kill -0 "$launcher" 2>/dev/null; then break; fi
  sleep 0.1
done
cat "$A_RUN_DIR/service.log" >&2 2>/dev/null || true; echo "A_START_FAILED service=$A_SERVICE_NAME port=$HOST:$PORT" >&2; exit 1
