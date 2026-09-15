#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"

[ -s "$A_PID_FILE" ] || { echo 'A_STOPPED=1 reason=not_running'; exit 0; }
pid=$(cat "$A_PID_FILE")
case "$pid" in *[!0-9]*|'') echo 'A_STOPPED=0 reason=invalid_pid'; exit 1 ;; esac
if [ ! -d "/proc/$pid" ]; then rm -f "$A_PID_FILE"; echo 'A_STOPPED=1 reason=already_exited'; exit 0; fi
[ "$(stat -c %u "/proc/$pid")" = "$(id -u "$AGENT_USER")" ] || { echo 'A_STOPPED=0 reason=uid_mismatch'; exit 1; }
cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline")
case "$cmdline" in *"$A_RUNTIME_DIR/service.py"*) ;; *) echo 'A_STOPPED=0 reason=unexpected_process'; exit 1 ;; esac
runuser -u "$AGENT_USER" -- kill -TERM "$pid"
for _ in $(seq 1 50); do
  if [ ! -d "/proc/$pid" ]; then rm -f "$A_PID_FILE"; echo "A_STOPPED=1 pid=$pid"; exit 0; fi
  state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  case "$state" in Z*) rm -f "$A_PID_FILE"; echo "A_STOPPED=1 pid=$pid state=$state"; exit 0 ;; esac
  sleep 0.1
done
kill -KILL "$pid" 2>/dev/null || true
rm -f "$A_PID_FILE"
echo "A_STOPPED=1 pid=$pid forced=1"
