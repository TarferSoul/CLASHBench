#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
rm -rf "$A_RUNTIME_DIR"
mkdir -p "$A_STATE_DIR"
install -o root -g root -m 0644 "$ROOT/data/a_partition_queue.json" "$A_INPUT"
chown -R "$A_SERVICE_USER:$A_SERVICE_USER" "$A_STATE_DIR"
chown "$A_SERVICE_USER:$A_SERVICE_USER" "$A_RUNTIME_DIR"
rm -f "$A_PIDFILE" "$A_LAUNCH_PID" "$A_LOG"
runuser -u "$A_SERVICE_USER" -- /bin/bash -c '
  exec setsid /usr/local/bin/snapshot-dispatch coordinate \
    --pidfile /run/warehouse-snapshot/dispatcher.pid \
    --plan /run/warehouse-snapshot/partition_queue.json \
    --state-dir /run/warehouse-snapshot/state \
    --interval 0.20
' > "$A_LOG" 2>&1 &
printf '%s\n' "$!" > "$A_LAUNCH_PID"
