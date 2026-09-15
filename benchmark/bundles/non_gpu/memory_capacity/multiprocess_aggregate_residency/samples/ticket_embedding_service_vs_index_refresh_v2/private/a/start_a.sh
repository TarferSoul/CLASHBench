#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

if [ -s "$A_RUNTIME_ROOT/service.pid" ]; then
  old_pid=$(cat "$A_RUNTIME_ROOT/service.pid" 2>/dev/null || true)
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    state=$(awk '{print $3}' "/proc/$old_pid/stat" 2>/dev/null || true)
    [ "$state" = Z ] || { echo "A_ALREADY_RUNNING pid=$old_pid" >&2; exit 1; }
  fi
fi

rm -rf "$A_STATE_ROOT"
install -d -o root -g root -m 755 "$A_RUNTIME_ROOT" "$A_RUN_ROOT"
install -d -o "$A_SERVICE_UID" -g "$A_SERVICE_GID" -m 700 "$A_STATE_ROOT" "$A_STATE_ROOT/workers"
run_dir="$A_RUN_ROOT/$(date -u +%Y%m%dT%H%M%SZ)_$$"
install -d -o "$A_SERVICE_UID" -g "$A_SERVICE_GID" -m 700 "$run_dir"

setsid setpriv --reuid="$A_SERVICE_UID" --regid="$A_SERVICE_GID" --init-groups \
  env -i PATH=/usr/local/bin:/usr/bin:/bin PYTHONUNBUFFERED=1 \
  "$A_PROGRAM" \
    --state-root "$A_STATE_ROOT" \
    --host "$A_HOST" \
    --port "$A_PORT" \
    --workers "$A_WORKER_COUNT" \
    --worker-resident-mib "$A_WORKER_RESIDENT_MIB" \
    --supervisor-resident-mib "$A_SUPERVISOR_RESIDENT_MIB" \
  >"$run_dir/service.log" 2>"$run_dir/service.stderr" &
pid=$!
printf '%s\n' "$pid" >"$A_RUNTIME_ROOT/service.pid"
ln -sfn "$run_dir" "$A_RUNTIME_ROOT/current"
chmod 600 "$A_RUNTIME_ROOT/service.pid"
echo "A_STARTED=1 pid=$pid workers=$A_WORKER_COUNT worker_resident_mib=$A_WORKER_RESIDENT_MIB supervisor_resident_mib=$A_SUPERVISOR_RESIDENT_MIB port=$A_PORT"
