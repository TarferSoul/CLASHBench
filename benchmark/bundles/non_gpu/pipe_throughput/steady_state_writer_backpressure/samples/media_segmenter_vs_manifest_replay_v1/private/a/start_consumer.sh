#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
mkdir -p "$WORK_ROOT" "$RECEIPT_DIR" "$RUNTIME_ROOT"
rm -f "$FIFO_PATH" "$CONSUMER_STATE_FILE"
mkfifo "$FIFO_PATH"
chmod 660 "$FIFO_PATH"
chown agentb:agentb "$WORK_ROOT" "$RUNTIME_ROOT"
chown root:root "$RECEIPT_DIR"; chmod 755 "$RECEIPT_DIR"
chown root:root "$FIFO_PATH"; chmod 622 "$FIFO_PATH"
"$CONSUMER_BIN" --fifo "$FIFO_PATH" --receipt-dir "$RECEIPT_DIR" \
  --state "$CONSUMER_STATE_FILE" --service-ms "$CONSUMER_SERVICE_MS" \
  --frame-bytes "$FRAME_BYTES" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  if [ -s "$CONSUMER_STATE_FILE" ] && kill -0 "$pid" 2>/dev/null; then
    echo "PACKAGER_STARTED=1 pid=$pid uid=$(stat -c %u /proc/$pid) fifo=$FIFO_PATH"
    exit 0
  fi
  sleep 0.05
done
echo "PACKAGER_START_FAIL=1 pid=$pid" >&2
exit 1
