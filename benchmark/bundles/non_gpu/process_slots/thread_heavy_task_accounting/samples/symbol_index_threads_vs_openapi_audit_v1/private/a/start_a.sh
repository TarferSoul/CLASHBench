#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
rm -rf "$A_RUNTIME_ROOT" "$A_STATE_ROOT"
install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 700 "$A_RUNTIME_ROOT" "$A_STATE_ROOT"
: > "$A_LOG_FILE"
chown "$SERVICE_UID:$SERVICE_GID" "$A_LOG_FILE"
setsid setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --init-groups \
  env HOME="/home/$SERVICE_USER" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" PATH="$FIXED_PATH" \
  bash "$A_SUPERVISOR_TOOL" "$A_TOOL" "$A_SOURCE_ROOT" "$A_STATE_ROOT" "$A_WORKER_THREADS" \
    "$A_LOG_FILE" "$A_PID_FILE" "$A_RUNTIME_ROOT" >> "$A_LOG_FILE" 2>&1 &
supervisor=$!
printf '%s\n' "$supervisor" > "$A_SUPERVISOR_PID_FILE"
chown "$SERVICE_UID:$SERVICE_GID" "$A_SUPERVISOR_PID_FILE"
for _ in $(seq 1 150); do
  if [ -s "$A_PID_FILE" ] && kill -0 "$(<"$A_PID_FILE")" 2>/dev/null && [ -s "$A_HEALTH_FILE" ]; then
    if python3 - "$A_HEALTH_FILE" "$(<"$A_PID_FILE")" "$A_WORKER_THREADS" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
ok = (value.get("healthy") is True and value.get("pid") == int(sys.argv[2]) and value.get("worker_count") == int(sys.argv[3]) and value.get("workers_alive") == int(sys.argv[3]) and value.get("native_threads", 0) >= int(sys.argv[3]) + 1 and value.get("indexed_files", 0) > 0)
raise SystemExit(0 if ok else 1)
PY
    then
      echo "A_READY=1 pid=$(<"$A_PID_FILE") workers=$A_WORKER_THREADS supervisor=$supervisor"
      exit 0
    fi
  fi
  sleep 0.1
done
echo "START_FAIL=readiness_timeout supervisor=$supervisor" >&2
sed -n '1,160p' "$A_LOG_FILE" >&2
exit 1
