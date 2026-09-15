#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/fixture.env"
bash "${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/a/stop_a.sh" >/dev/null 2>&1 || true
rm -f "$A_PID_FILE" "$A_EVENT_LOG" "$A_STDOUT"
install -d -o "$A_SERVICE_USER" -g "$A_SERVICE_USER" -m 755 "$A_RUNTIME_ROOT"
rm -f "$A_OUTPUT_FILE"
touch "$A_EVENT_LOG" "$A_STDOUT"
chmod 600 "$A_EVENT_LOG" "$A_STDOUT"
exec 3>>"$A_EVENT_LOG"
setsid setpriv --reuid="$A_SERVICE_USER" --regid="$A_SERVICE_USER" --init-groups \
  "$A_PROGRAM" --event-fd 3 --output "$A_OUTPUT_FILE" --workers "$A_WORKERS" \
  --compute-seconds "$A_COMPUTE_SECONDS" --quiet-seconds "$A_QUIET_SECONDS" \
  --rounds "$A_WORK_ROUNDS" >"$A_STDOUT" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$A_PID_FILE"
chmod 600 "$A_PID_FILE"
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if [ -d "/proc/$pid" ] && [ "$(stat -c %u "/proc/$pid")" = "$(id -u "$A_SERVICE_USER")" ] && grep -q '"phase": "ready"' "$A_EVENT_LOG"; then
    printf 'A_START_OK=1 pid=%s uid=%s\n' "$pid" "$(stat -c %u "/proc/$pid")"
    exit 0
  fi
  sleep "$A_READY_DELAY_SECONDS"
done
echo "A_START_OK=0 reason=ready_timeout" >&2
exit 1
