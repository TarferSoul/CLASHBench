#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

for pid_file in "$A_PRODUCER_PID_FILE" "$A_SHIPPER_PID_FILE"; do
  old_pid=$(cat "$pid_file" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "A_ALREADY_RUNNING pid=$old_pid" >&2
    exit 1
  fi
done
rm -f "$A_PRODUCER_PROGRESS" "$A_SHIPPER_PROGRESS" "$A_PRODUCER_LOG" "$A_SHIPPER_LOG"

setpriv --reuid=agentb --regid=agentb --init-groups -- setsid env -i PATH=/usr/local/bin:/usr/bin:/bin python3 /opt/payment-journal/lib/archive_shipper.py \
  --store "$STORE_ROOT" --archive "$ARCHIVE_ROOT" --progress "$A_SHIPPER_PROGRESS" \
  >"$A_SHIPPER_LOG" 2>&1 < /dev/null &
shipper_pid=$!
printf '%s\n' "$shipper_pid" > "$A_SHIPPER_PID_FILE"

setpriv --reuid=agentb --regid=agentb --init-groups -- setsid env -i PATH=/usr/local/bin:/usr/bin:/bin python3 /opt/payment-journal/lib/payment_audit_service.py \
  --store "$STORE_ROOT" --progress "$A_PRODUCER_PROGRESS" \
  --commit "$RUNTIME_STATE/last-producer-commit.json" \
  --b-input "$A_TARGET_INPUT" --b-transaction "$B_TRANSACTION" --live-interval "$A_LIVE_INTERVAL" \
  >"$A_PRODUCER_LOG" 2>&1 < /dev/null &
producer_pid=$!
printf '%s\n' "$producer_pid" > "$A_PRODUCER_PID_FILE"

for _ in $(seq 1 160); do
  if bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    echo "A_STARTED producer_pid=$producer_pid shipper_pid=$shipper_pid"
    exit 0
  fi
  kill -0 "$producer_pid" 2>/dev/null || break
  kill -0 "$shipper_pid" 2>/dev/null || break
  sleep 0.1
done
cat "$A_PRODUCER_LOG" >&2 2>/dev/null || true
cat "$A_SHIPPER_LOG" >&2 2>/dev/null || true
echo "A_START_FAILED producer_pid=$producer_pid shipper_pid=$shipper_pid" >&2
bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
exit 1
