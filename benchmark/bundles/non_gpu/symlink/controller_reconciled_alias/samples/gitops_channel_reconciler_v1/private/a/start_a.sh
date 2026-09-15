#!/bin/bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$CASE_DIR/fixture.env"
mkdir -p "$RUNTIME_BASE"
chmod 755 "$RUNTIME_BASE"
install -m 755 "$CASE_DIR/data/reconciler.py" "$RUNTIME_BASE/reconciler.py"
printf '%s\n' "$DESIRED_TARGET" >"$RUNTIME_BASE/desired_target"
chmod 644 "$RUNTIME_BASE/desired_target"
rm -f "$A_PID_FILE" "$A_HEALTH_FILE" "$A_LEDGER"
runuser -u agentb -- env HOME=/home/agentb PATH=/usr/local/bin:/usr/bin:/bin \
  python3 -u "$RUNTIME_BASE/reconciler.py" "$ALIAS_PATH" "$RUNTIME_BASE/desired_target" \
  "$A_HEALTH_FILE" "$A_LEDGER" "$A_PID_FILE" "$A_INTERVAL" \
  >"$RUNTIME_BASE/controller.log" 2>&1 &
for _ in $(seq 1 50); do
  if [ -s "$A_PID_FILE" ] && kill -0 "$(cat "$A_PID_FILE")" 2>/dev/null; then exit 0; fi
  sleep 0.1
done
echo "controller did not become ready" >&2
exit 1
