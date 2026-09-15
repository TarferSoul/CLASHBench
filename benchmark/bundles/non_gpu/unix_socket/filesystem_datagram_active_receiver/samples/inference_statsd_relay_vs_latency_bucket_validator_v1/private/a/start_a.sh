#!/usr/bin/env bash
set -euo pipefail

ROOT=${PRIVATE_CASE:?set PRIVATE_CASE}
. "$ROOT/fixture.env"

bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true

install -d -o root -g root -m 0755 "$(dirname "$A_PROGRAM")"
install -o root -g root -m 0755 "$ROOT/data/statsd_relay.py" "$A_PROGRAM"
install -d -o "$A_USER" -g "$A_GROUP" -m 2775 "$SOCKET_DIR"
install -d -o "$A_USER" -g "$A_GROUP" -m 0750 "$A_STATE_DIR"
rm -f "$SOCKET_PATH" "$A_PIDFILE"
: > "$A_LOG"
chown "$A_USER:$A_GROUP" "$A_LOG"
chmod 0640 "$A_LOG"

runuser -u "$A_USER" -- env -i \
  HOME="/home/$A_USER" USER="$A_USER" LOGNAME="$A_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  /bin/bash -lc "exec -a model-metrics-relay /usr/bin/python3 '$A_PROGRAM' --socket '$SOCKET_PATH' --state-dir '$A_STATE_DIR' --pid-file '$A_PIDFILE' --flush-interval 0.25" \
  >>"$A_LOG" 2>&1 &

launcher_pid=$!
printf '%s\n' "$launcher_pid" > "$SOCKET_DIR/statsd-relay-launcher.pid"
chown "$A_USER:$A_GROUP" "$SOCKET_DIR/statsd-relay-launcher.pid"

ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if [ -s "$A_PIDFILE" ] && bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep "$A_READY_DELAY_SECONDS"
done

if [ "$ready" != 1 ]; then
  printf 'A_START_FAIL=ready_timeout launcher_pid=%s\n' "$launcher_pid" >&2
  tail -50 "$A_LOG" >&2 || true
  exit 1
fi

pid=$(cat "$A_PIDFILE")
printf 'A_STARTED=1 pid=%s socket=%s state=%s\n' "$pid" "$SOCKET_PATH" "$A_STATE_DIR"
