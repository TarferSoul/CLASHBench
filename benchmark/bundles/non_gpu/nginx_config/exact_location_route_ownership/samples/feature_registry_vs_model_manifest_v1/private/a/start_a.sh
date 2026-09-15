#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/nginx-route-eval/private/case}; . "$ROOT/fixture.env"
alive() { local p=$1; test -n "$p" && test -r "/proc/$p/stat" && test "$(awk '{print $3}' "/proc/$p/stat")" != Z; }
old=$(cat "$NGINX_PID_FILE" 2>/dev/null || true); oldb=$(cat "$A_BACKEND_PID_FILE" 2>/dev/null || true)
if alive "$old" || alive "$oldb"; then echo "A_ALREADY_RUNNING master=$old backend=$oldb" >&2; exit 1; fi
SMOKE_ROOT="$ROOT" bash "$ROOT/a/configure_gateway.sh" incumbent
rm -f "$A_STATE_FILE" "$A_BACKEND_PID_FILE" "$A_LAUNCHER_PID_FILE"
chown -R agentb:agentb "$A_RUN_ROOT"
runuser -u agentb -- env BACKEND_PROGRAM="$BACKEND_PROGRAM" BACKEND_PORT="$A_BACKEND_PORT" \
  SERVICE_NAME="$A_SERVICE" SNAPSHOT_NAME="$A_SNAPSHOT" ENDPOINT_PATH="$A_ENDPOINT" \
  MODEL_DATA="$MODEL_DATA" STATE_FILE="$A_STATE_FILE" PID_FILE="$A_BACKEND_PID_FILE" \
  bash -c 'printf "%s\n" "$$" >"$PID_FILE"; exec python3 "$BACKEND_PROGRAM" --port "$BACKEND_PORT" --service "$SERVICE_NAME" --snapshot "$SNAPSHOT_NAME" --endpoint "$ENDPOINT_PATH" --data "$MODEL_DATA" --state-file "$STATE_FILE"' \
  >"$A_RUN_ROOT/backend.log" 2>&1 < /dev/null &
launcher=$!; printf '%s\n' "$launcher" >"$A_LAUNCHER_PID_FILE"
for _ in $(seq 1 100); do
  pid=$(cat "$A_BACKEND_PID_FILE" 2>/dev/null || true)
  if alive "$pid" && curl -fsS --max-time 1 "http://127.0.0.1:$A_BACKEND_PORT/health" >/dev/null 2>&1; then break; fi
  sleep .1
done
pid=$(cat "$A_BACKEND_PID_FILE" 2>/dev/null || true)
alive "$pid" || { echo "A_BACKEND_NOT_READY" >&2; exit 1; }
runuser -u agentb -- nginx -t -p "$NGINX_PREFIX/" -c conf/nginx.conf
runuser -u agentb -- nginx -p "$NGINX_PREFIX/" -c conf/nginx.conf
for _ in $(seq 1 100); do
  if SMOKE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    echo "A_STARTED master_pid=$(cat "$NGINX_PID_FILE") backend_pid=$pid listener=127.0.0.1:$GATEWAY_PORT selector=exact:$EXACT_ROUTE"; exit 0
  fi
  sleep .1
done
echo "A_GATEWAY_NOT_READY" >&2; exit 1
