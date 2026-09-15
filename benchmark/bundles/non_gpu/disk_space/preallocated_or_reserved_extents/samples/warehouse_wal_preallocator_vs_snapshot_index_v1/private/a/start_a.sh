#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
. "$CASE_PRIVATE_ROOT/data/volume_lib.sh"
mkdir -p "$A_DIR"
chown agentb:agentb "$A_DIR"
chmod 0770 "$A_DIR"
rm -f "$A_FILE" "$A_PROGRESS" "$A_PID_FILE" "$A_LOG"
reserve=$(compute_a_reserve_bytes)
setsid runuser -u agentb -- "$INCUMBENT_TOOL" \
  --file "$A_FILE" --progress "$A_PROGRESS" --pid-file "$A_PID_FILE" \
  --reserve-bytes "$reserve" --header "$A_HEADER" \
  </dev/null >"$A_LOG" 2>&1 &
launcher_pid=$!
printf '%s\n' "$launcher_pid" >/run/ml_bench/warehouse_recovery_launcher.pid
for _ in $(seq 1 80); do
  if [ -s "$A_PID_FILE" ]; then
    pid=$(cat "$A_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      printf 'A_START_OK=1 pid=%s reserve_bytes=%s launcher_pid=%s\n' "$pid" "$reserve" "$launcher_pid"
      exit 0
    fi
  fi
  sleep 0.1
done
cat "$A_LOG" >&2 2>/dev/null || true
echo 'A_START_OK=0 reason=worker_not_started'
exit 1

