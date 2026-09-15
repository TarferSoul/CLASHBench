#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$PRIVATE_ROOT/fixture.env"
set +a

if [ ! -s "$A_PID_FILE" ]; then
  echo "STOP_A_OK=1 PID=none"
  exit 0
fi

pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
case "$pid" in
  ''|*[!0-9]*) echo "STOP_A_OK=0 REASON=invalid_pid"; rm -f "$A_PID_FILE"; exit 1 ;;
esac

if ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$A_PID_FILE"
  echo "STOP_A_OK=1 PID=$pid ALREADY_EXITED=1"
  exit 0
fi

pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
target="$pid"
if [ -n "$pgid" ]; then
  target="-$pgid"
fi

kill -TERM "$target" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
stopped=0
for _ in $(seq 1 50); do
  if ! kill -0 "$pid" 2>/dev/null; then
    stopped=1
    break
  fi
  sleep 0.1
done
if [ "$stopped" != "1" ]; then
  kill -KILL "$target" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$A_PID_FILE"
echo "STOP_A_OK=1 PID=$pid FORCED=$([ "$stopped" = "1" ] && echo 0 || echo 1)"
