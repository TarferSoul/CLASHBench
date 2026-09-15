#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
: "${A_PROGRAM_ROOT:?A_PROGRAM_ROOT must point to the agent-owned workload copy}"
AGENT_USER=${BENCHMARK_AGENT_USER:-agentb}

pid=$(cat "$COLLECTOR_RUNTIME/collector.pid" 2>/dev/null || true)
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  echo "COLLECTOR_ALREADY_RUNNING pid=$pid"
  exit 0
fi

rm -rf "$COLLECTOR_RUNTIME" "$ROUTER_ROOT"
mkdir -p "$COLLECTOR_RUNTIME" "$ROUTER_ROOT" "$(dirname "$COLLECTOR_ARCHIVE")"
chown -R "$AGENT_USER:$AGENT_USER" "$COLLECTOR_RUNTIME" "$ROUTER_ROOT" "$(dirname "$COLLECTOR_ARCHIVE")"
chmod 700 "$COLLECTOR_RUNTIME" "$(dirname "$COLLECTOR_ARCHIVE")"
chmod 755 "$ROUTER_ROOT"
rm -f "$COLLECTOR_ARCHIVE"
runuser -u "$AGENT_USER" -- env \
  FIFO_PATH="$FIFO_PATH" COLLECTOR_RUNTIME="$COLLECTOR_RUNTIME" \
  COLLECTOR_ARCHIVE="$COLLECTOR_ARCHIVE" FRAME_BYTES="$FRAME_BYTES" \
  PIPE_TARGET_CAPACITY="$PIPE_TARGET_CAPACITY" COLLECTOR_SERVICE_MS="$COLLECTOR_SERVICE_MS" \
  python3 "$A_PROGRAM_ROOT/data/telemetry_collector.py" \
  >"$COLLECTOR_RUNTIME/collector.log" 2>&1 </dev/null &
launcher_pid=$!
for _ in $(seq 1 100); do
  if kill -0 "$launcher_pid" 2>/dev/null && [ -s "$COLLECTOR_RUNTIME/status.json" ] && [ -p "$FIFO_PATH" ]; then
    pid=$(python3 - "$COLLECTOR_RUNTIME/status.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['pid'])
PY
)
    printf '%s\n' "$pid" >"$COLLECTOR_RUNTIME/collector.pid"
    echo "COLLECTOR_STARTED pid=$pid fifo=$FIFO_PATH uid=$(stat -c %u /proc/$pid)"
    exit 0
  fi
  sleep 0.05
done
echo "COLLECTOR_START_FAILED launcher_pid=$launcher_pid" >&2
tail -80 "$COLLECTOR_RUNTIME/collector.log" >&2 2>/dev/null || true
exit 1
