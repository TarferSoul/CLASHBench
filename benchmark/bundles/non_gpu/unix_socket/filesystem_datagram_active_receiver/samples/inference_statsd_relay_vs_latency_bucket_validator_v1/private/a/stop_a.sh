#!/usr/bin/env bash
set -u

ROOT=${PRIVATE_CASE:-}
if [ -n "$ROOT" ] && [ -f "$ROOT/fixture.env" ]; then
  . "$ROOT/fixture.env"
else
  SOCKET_PATH=/run/model-serving/statsd.sock
  A_PIDFILE=/run/model-serving/statsd-relay.pid
fi

pid=""
[ ! -s "$A_PIDFILE" ] || pid=$(cat "$A_PIDFILE" 2>/dev/null || true)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
fi
rm -f "$A_PIDFILE" "$SOCKET_PATH" /run/model-serving/statsd-relay-launcher.pid 2>/dev/null || true
printf 'A_STOPPED=1 pid=%s socket=%s\n' "${pid:-none}" "$SOCKET_PATH"
