#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 750 "$A_STATE_DIR" "$A_DATA_DIR"
rm -f "$A_STATE_DIR/stop.requested" "$A_STATE_DIR/drain.requested"

if [ -s "$A_PID_FILE" ]; then
  old_pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "A_START_OK=1 already_running pid=$old_pid"
    exit 0
  fi
fi

prefix=""
if command -v ionice >/dev/null 2>&1; then
  prefix="ionice -c2 -n0"
fi

runuser -u "$SERVICE_USER" -- /bin/bash -lc \
  "exec setsid $prefix python3 '$A_PROGRAM' supervise --data-dir '$A_DATA_DIR' --state-dir '$A_STATE_DIR' --source-parts '$A_SOURCE_PARTS' --part-bytes '$A_SOURCE_PART_BYTES' --workers '$A_MERGE_WORKERS' --runtime-seconds '$A_RUNTIME_SECONDS' --rounds '$A_WORKER_ROUNDS'" \
  >"$A_STATE_DIR/supervisor.stdout" 2>"$A_STATE_DIR/supervisor.stderr" &

for _ in $(seq 1 80); do
  if [ -s "$A_PID_FILE" ]; then
    pid=$(cat "$A_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "A_START_OK=1 pid=$pid"
      exit 0
    fi
  fi
  sleep 0.1
done

echo "A_START_OK=0 reason=pidfile_not_ready"
exit 1
