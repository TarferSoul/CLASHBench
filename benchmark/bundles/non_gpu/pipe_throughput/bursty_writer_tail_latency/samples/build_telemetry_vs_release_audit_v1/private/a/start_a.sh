#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
: "${A_PROGRAM_ROOT:?A_PROGRAM_ROOT must point to the agent-owned workload copy}"
AGENT_USER=${BENCHMARK_AGENT_USER:-agentb}
bash "$ROOT/a/start_collector.sh"

pid=$(cat "$A_RUNTIME/agent.pid" 2>/dev/null || true)
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  echo "A_ALREADY_RUNNING pid=$pid" >&2
  exit 1
fi
rm -rf "$A_RUNTIME"
mkdir -p "$A_RUNTIME"
chown "$AGENT_USER:$AGENT_USER" "$A_RUNTIME"
chmod 700 "$A_RUNTIME"
runuser -u "$AGENT_USER" -- env \
  FIFO_PATH="$FIFO_PATH" A_RUNTIME="$A_RUNTIME" FRAME_BYTES="$FRAME_BYTES" \
  A_BURST_RECORDS="$A_BURST_RECORDS" A_BUFFER_INTERVAL_SEC="$A_BUFFER_INTERVAL_SEC" \
  python3 "$A_PROGRAM_ROOT/data/build_telemetry_agent.py" \
  >"$A_RUNTIME/agent.log" 2>&1 </dev/null &
launcher_pid=$!
for _ in $(seq 1 100); do
  if kill -0 "$launcher_pid" 2>/dev/null && [ -s "$A_RUNTIME/status.json" ]; then
    pid=$(python3 - "$A_RUNTIME/status.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['pid'])
PY
)
    printf '%s\n' "$pid" >"$A_RUNTIME/agent.pid"
    echo "A_STARTED pid=$pid status=$A_RUNTIME/status.json uid=$(stat -c %u /proc/$pid)"
    exit 0
  fi
  sleep 0.05
done
echo "A_START_FAILED launcher_pid=$launcher_pid" >&2
tail -80 "$A_RUNTIME/agent.log" >&2 2>/dev/null || true
exit 1
