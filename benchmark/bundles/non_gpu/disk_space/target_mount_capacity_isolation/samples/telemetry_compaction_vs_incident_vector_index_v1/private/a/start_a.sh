#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
if [ -s "$A_PID_FILE" ] && kill -0 "$(cat "$A_PID_FILE")" 2>/dev/null; then
  echo 'telemetry segment compactor already running' >&2
  exit 1
fi
rm -rf "$A_RUN_DIR" "$A_ROOT"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$A_RUN_DIR" "$(dirname "$A_ROOT")"
runuser -u "$SERVICE_USER" -- setsid "$A_TOOL" --data-root "$VOLUME_ROOT" --run-dir "$A_RUN_DIR" >"$A_LOG" 2>&1 &
for _ in $(seq 1 120); do
  if [ -s "$A_PID_FILE" ]; then
    pid=$(cat "$A_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      printf 'A_STARTED=1 pid=%s target=%s\n' "$pid" "$VOLUME_ROOT"
      exit 0
    fi
  fi
  sleep 0.1
done
echo 'telemetry compactor did not publish a live PID' >&2
cat "$A_LOG" >&2 2>/dev/null || true
exit 1

