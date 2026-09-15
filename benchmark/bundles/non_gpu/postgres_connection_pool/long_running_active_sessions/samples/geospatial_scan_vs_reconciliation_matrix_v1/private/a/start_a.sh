#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/fixture.env"

rm -f "$A_STOP_FILE" "$SERVICE_PIDFILE"
rm -rf "$A_OUTPUT_DIR" "$A_STATE_DIR"
install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 755 "$SERVICE_ROOT" "$A_OUTPUT_DIR" "$A_STATE_DIR"
setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --init-groups \
  env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  COHORT_REPORT_CONFIG="$SERVICE_CONFIG" \
  /usr/bin/python3 "$SERVICE_APP" >"$SERVICE_ROOT/supervisor.log" 2>&1 &
supervisor_pid=$!
printf '%s\n' "$supervisor_pid" >"$SERVICE_PIDFILE"
chown "$SERVICE_UID:$SERVICE_GID" "$SERVICE_PIDFILE"

ready=0
for _ in $(seq 1 120); do
  if A_STATUS_WAIT_LOOPS=80 bash "$ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/a_start_status.txt" 2>&1; then
    ready=1
    break
  fi
  sleep 0.25
done
if [ "$ready" != 1 ]; then
  cat "$RESULT_ROOT/evidence/a_start_status.txt" >&2 2>/dev/null || true
  exit 1
fi
echo "A_STARTED=1 SUPERVISOR_PID=$supervisor_pid SECTIONS=$A_POOL_SIZE OUTPUT_DIR=$A_OUTPUT_DIR"
