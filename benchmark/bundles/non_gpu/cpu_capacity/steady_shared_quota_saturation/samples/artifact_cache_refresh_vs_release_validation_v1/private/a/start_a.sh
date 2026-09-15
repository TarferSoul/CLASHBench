#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
bash "$(dirname "$0")/stop_a.sh" >/dev/null 2>&1 || true
install -d -o agentb -g agentb -m 755 "$A_STATE_ROOT" "$A_STATE_ROOT/progress" "$A_STATE_ROOT/products"
runuser -u agentb -- setsid "$A_PROGRAM" --catalog "$B_INPUT_PATH" --state "$A_STATE_ROOT" \
  --workers "$A_WORKERS" --rounds "$A_KERNEL_ROUNDS" >"$A_STATE_ROOT/service.log" 2>&1 &
launcher=$!
printf '%s\n' "$launcher" >"$A_STATE_ROOT/launcher.pid"
chown agentb:agentb "$A_STATE_ROOT/launcher.pid"
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if [ -s "$A_STATE_ROOT/service.json" ]; then echo "A_START_OK=1 launcher_pid=$launcher"; exit 0; fi
  sleep "$A_READY_DELAY_SECONDS"
done
echo "A_START_OK=0 reason=state_timeout" >&2
exit 1
