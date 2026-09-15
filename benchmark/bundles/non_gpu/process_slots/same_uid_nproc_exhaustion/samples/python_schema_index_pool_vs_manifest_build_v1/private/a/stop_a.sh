#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/case-secret/case}
. "$ROOT/fixture.env"

if [ ! -f "$A_PID_FILE" ]; then
  python3 "$ROOT/data/account_inventory.py" "$SERVICE_UID" --require-count 0 >/dev/null
  echo "A_STOPPED=1 mode=already_absent uid_tasks=0"
  exit 0
fi
pid=$(cat "$A_PID_FILE")
kill -TERM "$pid" 2>/dev/null || true
for _ in $(seq 1 240); do
  if python3 "$ROOT/data/account_inventory.py" "$SERVICE_UID" --require-count 0 >/dev/null 2>&1; then
    rm -f "$A_PID_FILE"
    service_rc=unknown
    [ -f "$A_EXIT_FILE" ] && service_rc=$(cat "$A_EXIT_FILE")
    echo "A_STOPPED=1 mode=graceful uid_tasks=0 service_rc=$service_rc"
    exit 0
  fi
  sleep 0.05
done
echo "A_STOPPED=0 supervisor_pid=$pid reason=graceful_timeout" >&2
exit 1
