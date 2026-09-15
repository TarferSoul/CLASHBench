#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
rm -rf "$A_RUNTIME_ROOT"
install -d -o root -g root -m 755 "$A_RUNTIME_ROOT"
install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 700 "$A_STATE_ROOT"
install -d -o root -g root -m 755 "$A_RUNTIME_ROOT/logs"

setsid setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --init-groups \
  "$A_PROGRAM" serve \
  --workers "$A_WORKER_COUNT" \
  --worker-mib "$A_WORKER_RESIDENT_MIB" \
  --supervisor-mib "$A_SUPERVISOR_RESIDENT_MIB" \
  --state-dir "$A_STATE_ROOT" \
  --salt "$A_EXPECTED_CANARY_SALT" \
  >"$A_RUNTIME_ROOT/logs/service.stdout" 2>"$A_RUNTIME_ROOT/logs/service.stderr" &
pid=$!
printf '%s\n' "$pid" >"$A_RUNTIME_ROOT/supervisor.pid"
chmod 600 "$A_RUNTIME_ROOT/supervisor.pid"
echo "A_START=1 supervisor_pid=$pid workers=$A_WORKER_COUNT resident_mib=$A_WORKER_RESIDENT_MIB"
