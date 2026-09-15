#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/fixture.env"
: "${INSTALL_ROOT:?}"
state=${A_STATE_ROOT:?}
mkdir -p "$state"
chown agentb:agentb "$state"
chmod 700 "$state"
rm -f "$state"/*.pid "$state"/*.starttime "$state"/*.json "$state"/*.jsonl "$state"/*.log

wait_port() {
  python3 - "$1" "$2" <<'PY'
import socket, sys, time
deadline=time.time()+8
while time.time()<deadline:
    try:
        with socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=.15): pass
        raise SystemExit(0)
    except OSError: time.sleep(.04)
raise SystemExit(1)
PY
}

runuser -u agentb -- /bin/sh -c "echo \$\$ > '$state/receiver.pid'; exec /usr/bin/python3 '$INSTALL_ROOT/artifact_receiver.py' --host '$BACKEND_HOST' --port '$BACKEND_PORT' --state '$state' --pid-file '$state/receiver.pid'" >"$state/receiver.log" 2>&1 &
wait_port "$BACKEND_HOST" "$BACKEND_PORT"
receiver_pid=$(cat "$state/receiver.pid")
awk '{print $22}' "/proc/$receiver_pid/stat" >"$state/receiver.starttime"

/usr/bin/python3 "$INSTALL_ROOT/egress_gateway.py" --listen-host "$GATEWAY_HOST" --listen-port "$GATEWAY_PORT" --backend-host "$BACKEND_HOST" --backend-port "$BACKEND_PORT" --rate-bytes-per-second "$EGRESS_RATE_BYTES_PER_SECOND" --stats "$state/gateway_stats.json" --events "$state/gateway_events.jsonl" --pid-file "$state/gateway.pid" >"$state/gateway.log" 2>&1 &
for _ in $(seq 1 120); do [ -s "$state/gateway.pid" ] && wait_port "$GATEWAY_HOST" "$GATEWAY_PORT" && break; sleep .03; done
[ -s "$state/gateway.pid" ] || { echo "SETUP_FAIL=GATEWAY_PID_MISSING" >&2; exit 3; }
gateway_pid=$(cat "$state/gateway.pid")
awk '{print $22}' "/proc/$gateway_pid/stat" >"$state/gateway.starttime"

if [ "${START_ONLY_INFRA:-0}" = 1 ]; then
  echo "A_INFRA_STARTED=1 receiver_pid=$receiver_pid gateway_pid=$gateway_pid gateway=$GATEWAY_HOST:$GATEWAY_PORT"
  exit 0
fi

runuser -u agentb -- /bin/sh -c "echo \$\$ > '$state/publisher.pid'; exec /usr/bin/python3 '$INSTALL_ROOT/continuous_publisher.py' --host '$GATEWAY_HOST' --port '$GATEWAY_PORT' --state '$state' --context '$A_CONTEXT' --kind '$A_KIND' --prefix '$A_PREFIX' --revision '$A_REVISION' --workers '$A_WORKERS' --chunk-bytes '$A_CHUNK_BYTES' --pid-file '$state/publisher.pid'" >"$state/publisher.log" 2>&1 &
for _ in $(seq 1 120); do [ -s "$state/publisher.pid" ] && break; sleep .03; done
[ -s "$state/publisher.pid" ] || { echo "SETUP_FAIL=PUBLISHER_PID_MISSING" >&2; exit 3; }
publisher_pid=$(cat "$state/publisher.pid")
awk '{print $22}' "/proc/$publisher_pid/stat" >"$state/publisher.starttime"
chown agentb:agentb "$state/receiver.pid" "$state/receiver.starttime" "$state/publisher.pid" "$state/publisher.starttime" "$state/receiver.log" "$state/publisher.log" 2>/dev/null || true
echo "A_STARTED=1 publisher_pid=$publisher_pid receiver_pid=$receiver_pid gateway_pid=$gateway_pid lane=$GATEWAY_HOST:$GATEWAY_PORT context=$A_CONTEXT"

