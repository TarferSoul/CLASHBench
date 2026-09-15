#!/usr/bin/env bash
set -euo pipefail
part=$1
case "$part" in service|scheduler|all) ;; *) echo "unknown component=$part" >&2; exit 2 ;; esac
mkdir -p "$A_RUNTIME" "$A_OUTPUT"
chown agentb:agentb "$A_RUNTIME" "$A_OUTPUT"

start_service() {
  if [ -s "$SERVICE_PID_FILE" ] && kill -0 "$(jq -r .pid "$SERVICE_PID_FILE" 2>/dev/null || printf 0)" 2>/dev/null; then return; fi
  printf 'SERVICE_LAUNCH=1 port=%s path=%s pool=%s runtime=%s\n' "$SERVICE_PORT" "$SERVICE_PATH" "$POOL_SIZE" "$A_RUNTIME" >> "$SERVICE_EVENT_LOG"
  runuser -u agentb -- /usr/bin/python3 "$INSTALL_ROOT/worker_service.py" --port "$SERVICE_PORT" --path "$SERVICE_PATH" --pool "$POOL_SIZE" --service-id "$SERVICE_ID" --runtime "$A_RUNTIME" >> "$SERVICE_EVENT_LOG" 2>&1 &
  for _ in $(seq 1 100); do
    if [ -s "$SERVICE_PID_FILE" ] && grep -q '"kind": "service_ready"' "$SERVICE_EVENT_LOG"; then return; fi
    sleep .05
  done
  echo "SETUP_FAIL=SERVICE_NOT_READY" >&2
  return 3
}

start_scheduler() {
  if [ -s "$SCHEDULER_PID_FILE" ] && kill -0 "$(jq -r .pid "$SCHEDULER_PID_FILE" 2>/dev/null || printf 0)" 2>/dev/null; then return; fi
  printf 'SCHEDULER_LAUNCH=1 endpoint=http://127.0.0.1:%s%s wave_size=%s duration_ms=%s period_ms=%s\n' "$SERVICE_PORT" "$SERVICE_PATH" "$A_WAVE_SIZE" "$A_REQUEST_MS" "$A_PERIOD_MS" >> "$A_EVENT_LOG"
  runuser -u agentb -- /usr/bin/python3 "$INSTALL_ROOT/incumbent_scheduler.py" --endpoint "http://127.0.0.1:$SERVICE_PORT$SERVICE_PATH" --pool "$POOL_SIZE" --wave-size "$A_WAVE_SIZE" --duration-ms "$A_REQUEST_MS" --period-ms "$A_PERIOD_MS" --units "$A_UNITS" --context "$A_CONTEXT" --runtime "$A_RUNTIME" --output "$A_OUTPUT" >> "$A_EVENT_LOG" 2>&1 &
  for _ in $(seq 1 60); do [ -s "$SCHEDULER_PID_FILE" ] && break; sleep .05; done
  [ -s "$SCHEDULER_PID_FILE" ] || { echo "SETUP_FAIL=SCHEDULER_NOT_READY" >&2; return 3; }
}

case "$part" in
  service) start_service ;;
  scheduler) start_scheduler ;;
  all) start_service; start_scheduler ;;
esac
printf 'A_STARTED=1 service=%s port=%s pool=%s context=%s\n' "$SERVICE_ID" "$SERVICE_PORT" "$POOL_SIZE" "$A_CONTEXT"
