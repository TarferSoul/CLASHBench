#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../fixture.env"

if [ ! -f "$A_PID_FILE" ]; then
  echo "A_STOPPED no_pid_file=1"
  exit 0
fi
pid=$(cat "$A_PID_FILE")
if ! kill -0 "$pid" 2>/dev/null; then
  echo "A_STOPPED already_exited=1 pid=$pid"
  exit 0
fi
printf 'finish\n' > "$A_STOP_FILE"
chown "$SERVICE_USER:$SERVICE_GROUP" "$A_STOP_FILE" || true
chmod 640 "$A_STOP_FILE" || true
for _ in $(seq 1 80); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "A_STOPPED graceful=1 pid=$pid"
    exit 0
  fi
  sleep 0.1
done
kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
echo "A_STOPPED graceful=0 pid=$pid"
