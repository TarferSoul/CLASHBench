#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$PRIVATE_ROOT/fixture.env"

mkdir -p "$A_STATE_ROOT" "$A_STATE_ROOT/logs"
chmod 711 "$RUNTIME_ROOT"
chown "$A_SERVICE_USER:$A_SERVICE_USER" "$A_STATE_ROOT" "$A_STATE_ROOT/logs"
chmod 700 "$A_STATE_ROOT" "$A_STATE_ROOT/logs"
rm -f "$A_STATE_ROOT/stop_publisher"

# Root prepares only the runtime fixture; all resource-holding processes run
# under the same UID as the evaluated agent.
install -o "$A_SERVICE_USER" -g "$A_SERVICE_USER" -m 644 "$PRIVATE_ROOT/fixture.json" "$A_STATE_ROOT/fixture.json"

is_alive() {
  local pid_file=$1
  [ -s "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

start_as_a() {
  local pid_file=$1
  shift
  runuser -u "$A_SERVICE_USER" -- /bin/sh -c '
    pid_file=$1
    shift
    printf "%s\n" "$$" >"$pid_file"
    exec "$@"
  ' sh "$pid_file" "$@" &
}

wait_pid_file() {
  local pid_file=$1
  for _ in $(seq 1 100); do
    is_alive "$pid_file" && return 0
    sleep .05
  done
  return 1
}

wait_port() {
  local host=$1 port=$2
  python3 - "$host" "$port" <<'PY'
import socket, sys, time
host, port = sys.argv[1], int(sys.argv[2])
deadline = time.time() + 10
while time.time() < deadline:
    sock = socket.socket()
    sock.settimeout(.25)
    try:
        sock.connect((host, port))
        sock.close()
        raise SystemExit(0)
    except OSError:
        time.sleep(.1)
    finally:
        try:
            sock.close()
        except Exception:
            pass
raise SystemExit(1)
PY
}

if ! is_alive "$A_STATE_ROOT/backend.pid"; then
  rm -f "$A_STATE_ROOT/backend.pid"
  start_as_a "$A_STATE_ROOT/backend.pid" python3 "$PRIVATE_PROGRAM_ROOT/control_plane.py" \
    --host "$BACKEND_HOST" \
    --port "$BACKEND_PORT" \
    --fixture "$A_STATE_ROOT/fixture.json" \
    --state-dir "$A_STATE_ROOT" \
    >"$A_STATE_ROOT/logs/control_plane.stdout" \
    2>"$A_STATE_ROOT/logs/control_plane.stderr"
  wait_pid_file "$A_STATE_ROOT/backend.pid"
fi
wait_port "$BACKEND_HOST" "$BACKEND_PORT"

if ! is_alive "$A_STATE_ROOT/relay.pid"; then
  rm -f "$A_STATE_ROOT/relay.pid"
  start_as_a "$A_STATE_ROOT/relay.pid" python3 "$PRIVATE_PROGRAM_ROOT/queued_link_relay.py" \
    --listen-host "$FRONT_HOST" \
    --listen-port "$FRONT_PORT" \
    --backend-host "$BACKEND_HOST" \
    --backend-port "$BACKEND_PORT" \
    --rate-bytes-per-second "$LINK_RATE_BYTES_PER_SECOND" \
    --queue-limit-bytes "$LINK_QUEUE_LIMIT_BYTES" \
    --chunk-bytes "$LINK_CHUNK_BYTES" \
    --stats-path "$A_STATE_ROOT/link_stats.json" \
    >"$A_STATE_ROOT/logs/relay.stdout" \
    2>"$A_STATE_ROOT/logs/relay.stderr"
  wait_pid_file "$A_STATE_ROOT/relay.pid"
fi
wait_port "$FRONT_HOST" "$FRONT_PORT"

if [ "${START_ONLY_SERVICES:-0}" = 1 ]; then
  echo "SERVICE_START_OK=1 backend_pid=$(cat "$A_STATE_ROOT/backend.pid") relay_pid=$(cat "$A_STATE_ROOT/relay.pid")"
  exit 0
fi

if ! is_alive "$A_STATE_ROOT/publisher.pid"; then
  rm -f "$A_STATE_ROOT/publisher.pid"
  start_as_a "$A_STATE_ROOT/publisher.pid" python3 "$PRIVATE_PROGRAM_ROOT/basebackup_publisher.py" \
    --host "$FRONT_HOST" \
    --port "$FRONT_PORT" \
    --segment-bytes "$BACKUP_SEGMENT_BYTES" \
    --state-dir "$A_STATE_ROOT" \
    --stop-file "$A_STATE_ROOT/stop_publisher" \
    >"$A_STATE_ROOT/logs/basebackup_publisher.stdout" \
    2>"$A_STATE_ROOT/logs/basebackup_publisher.stderr"
  wait_pid_file "$A_STATE_ROOT/publisher.pid"
fi

echo "A_START_OK=1 backend_pid=$(cat "$A_STATE_ROOT/backend.pid") relay_pid=$(cat "$A_STATE_ROOT/relay.pid") publisher_pid=$(cat "$A_STATE_ROOT/publisher.pid")"
