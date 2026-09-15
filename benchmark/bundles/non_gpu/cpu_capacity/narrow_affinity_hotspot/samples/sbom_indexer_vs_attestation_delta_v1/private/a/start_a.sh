#!/usr/bin/env bash
set -euo pipefail
PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$PRIVATE_ROOT/fixture.env"
. "$LANE_CONFIG"
mkdir -p "$A_RUNTIME_ROOT"
chown -R "$A_SERVICE_USER:$A_SERVICE_USER" "$A_RUNTIME_ROOT"
chmod 700 "$A_RUNTIME_ROOT"
if [ -s "$A_RUNTIME_ROOT/launcher.pid" ]; then
  old_pid=$(<"$A_RUNTIME_ROOT/launcher.pid")
  if kill -0 "$old_pid" 2>/dev/null; then echo "A_STARTED already=1 pid=$old_pid"; exit 0; fi
fi
rm -f "$A_RUNTIME_ROOT/state.json" "$A_RUNTIME_ROOT/epochs.jsonl"
setsid setpriv --reuid="$A_SERVICE_USER" --regid="$A_SERVICE_USER" --init-groups \
  env -i PATH=/usr/local/bin:/usr/bin:/bin PYTHONUNBUFFERED=1 \
  taskset -c "$CPU_LIST" "$A_PROGRAM" --state-root "$A_RUNTIME_ROOT" \
  >"$A_RUNTIME_ROOT/service.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$A_RUNTIME_ROOT/launcher.pid"
for _ in $(seq 1 50); do
  [ -d "/proc/$pid" ] && [ "$(stat -c %u "/proc/$pid")" = "$(id -u "$A_SERVICE_USER")" ] && break
  sleep 0.02
done
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
printf '%s\n' "$pgid" >"$A_RUNTIME_ROOT/launcher.pgid"
chown "$A_SERVICE_USER:$A_SERVICE_USER" "$A_RUNTIME_ROOT/launcher.pid" "$A_RUNTIME_ROOT/launcher.pgid"
echo "A_STARTED pid=$pid pgid=$pgid lane=$CPU_LIST"
