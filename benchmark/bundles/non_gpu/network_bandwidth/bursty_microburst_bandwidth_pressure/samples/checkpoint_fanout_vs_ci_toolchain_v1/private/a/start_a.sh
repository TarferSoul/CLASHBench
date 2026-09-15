#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/fixture.env"
state=${A_STATE_ROOT:-/run/network-bandwidth-state}
: "${INSTALL_ROOT:?}"
mkdir -p "$state"; chown -R agentb:agentb "$state"; chmod 700 "$state"
rm -f "$state"/*.pid "$state"/*.starttime "$state"/*.json "$state"/*.jsonl "$state"/*.log
runuser -u agentb -- /usr/bin/python3 "$INSTALL_ROOT/transfer_receiver.py" --host "$RECEIVER_HOST" --port "$RECEIVER_PORT" --state "$state" --pid-file "$state/receiver.pid" >"$state/receiver.log" 2>&1 &
for _ in $(seq 1 120); do [ -s "$state/receiver.pid" ] && [ -s "$state/receiver.json" ] && break; sleep .02; done
[ -s "$state/receiver.pid" ] || { echo "SETUP_FAIL=RECEIVER_PID_MISSING" >&2; exit 3; }
receiver_pid=$(cat "$state/receiver.pid"); awk '{print $22}' "/proc/$receiver_pid/stat" >"$state/receiver.starttime"
a_cycles=${A_CYCLES:-$A_RUNTIME_CYCLES}
runuser -u agentb -- /usr/bin/python3 "$INSTALL_ROOT/segment_publisher.py" --host "$RECEIVER_HOST" --port "$RECEIVER_PORT" --state "$state" --cycles "$a_cycles" --renditions "$A_RENDITIONS" --segment-bytes "$A_SEGMENT_BYTES" --phase-lead-ms "$A_PHASE_LEAD_MS" --quiet-ms "$A_QUIET_MS" --pid-file "$state/publisher.pid" >"$state/publisher.log" 2>&1 &
for _ in $(seq 1 120); do [ -s "$state/publisher.pid" ] && break; sleep .02; done
[ -s "$state/publisher.pid" ] || { echo "SETUP_FAIL=PUBLISHER_PID_MISSING" >&2; exit 3; }
publisher_pid=$(cat "$state/publisher.pid"); awk '{print $22}' "/proc/$publisher_pid/stat" >"$state/publisher.starttime"
chown agentb:agentb "$state"/*.pid "$state"/*.starttime "$state"/*.log 2>/dev/null || true
echo "A_STARTED=1 receiver_pid=$receiver_pid publisher_pid=$publisher_pid port=$RECEIVER_PORT context=$A_CONTEXT"

