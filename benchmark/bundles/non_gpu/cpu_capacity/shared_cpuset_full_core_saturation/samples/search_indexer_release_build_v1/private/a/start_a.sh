#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
. "$CPU_ENV"

if [ -s "$A_PID_FILE" ] && kill -0 "$(cat "$A_PID_FILE")" 2>/dev/null; then
  echo "A_STARTED=0 REASON=ALREADY_RUNNING" >&2
  exit 1
fi
install -d -o root -g root -m 700 "$A_CONTROL_ROOT"
rm -f "$A_PID_FILE" "$A_CONTROL_ROOT/service.log"
setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --init-groups \
  setsid "$A_PROGRAM" --cpus "$CPU_LIST" --port "$A_PORT" \
  >"$A_CONTROL_ROOT/service.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$A_PID_FILE"
chmod 600 "$A_PID_FILE" "$A_CONTROL_ROOT/service.log"
sleep 0.10
if ! kill -0 "$pid" 2>/dev/null; then
  echo "A_STARTED=0 REASON=EARLY_EXIT" >&2
  cat "$A_CONTROL_ROOT/service.log" >&2 || true
  exit 1
fi
[ "$(stat -c %u "/proc/$pid")" = "$SERVICE_UID" ] || {
  echo "A_STARTED=0 REASON=WRONG_UID" >&2
  exit 1
}
echo "A_STARTED=1 PID=$pid CPU_LIST=$CPU_LIST"
