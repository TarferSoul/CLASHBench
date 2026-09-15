#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
uid=$(id -u agentb); gid=$(id -g agentb)
mkdir -p "$RUNTIME_ROOT"
chown agentb:agentb "$RUNTIME_ROOT"
rm -f "$A_STATE_FILE" "$A_PROGRESS_FILE"
setpriv --reuid="$uid" --regid="$gid" --init-groups --reset-env -- \
  "$A_BIN" --fifo "$FIFO_PATH" --receipt-dir "$RECEIPT_DIR" \
  --state "$A_STATE_FILE" --progress "$A_PROGRESS_FILE" \
  --frame-bytes "$FRAME_BYTES" --startup-records "$A_STARTUP_RECORDS" \
  --rate-rps "$A_RATE_RPS" --label ci >>"$RUNTIME_ROOT/a.log" 2>&1 &
pid=$!
for _ in $(seq 1 120); do
  if [ -s "$A_STATE_FILE" ] && [ -s "$A_PROGRESS_FILE" ] && kill -0 "$pid" 2>/dev/null; then
    echo "A_STARTED=1 pid=$pid uid=$(stat -c %u /proc/$pid) fifo=$FIFO_PATH"
    exit 0
  fi
  sleep 0.05
done
cat "$RUNTIME_ROOT/a.log" >&2 || true
echo "A_START_FAIL=1 pid=$pid" >&2
exit 1
