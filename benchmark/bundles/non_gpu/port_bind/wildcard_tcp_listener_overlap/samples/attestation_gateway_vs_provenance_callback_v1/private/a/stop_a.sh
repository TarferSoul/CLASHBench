#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"
[ -s "$A_PID_FILE" ] || { echo 'A_STOPPED=1 reason=not_running'; exit 0; }
pid=$(cat "$A_PID_FILE"); case "$pid" in *[!0-9]*|'') exit 1 ;; esac
if [ ! -d "/proc/$pid" ]; then rm -f "$A_PID_FILE"; echo 'A_STOPPED=1 reason=already_exited'; exit 0; fi
[ "$(stat -c %u "/proc/$pid")" = "$(id -u "$AGENT_USER")" ] || exit 1
case "$(tr '\0' ' ' <"/proc/$pid/cmdline")" in *"$A_RUNTIME_DIR/service.py"*) ;; *) exit 1 ;; esac
runuser -u "$AGENT_USER" -- kill -TERM "$pid"
for _ in $(seq 1 50); do
  if [ ! -d "/proc/$pid" ]; then rm -f "$A_PID_FILE"; echo "A_STOPPED=1 pid=$pid"; exit 0; fi
  case "$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)" in Z*) rm -f "$A_PID_FILE"; echo "A_STOPPED=1 pid=$pid"; exit 0 ;; esac
  sleep 0.1
done
kill -KILL "$pid" 2>/dev/null || true; rm -f "$A_PID_FILE"; echo "A_STOPPED=1 pid=$pid forced=1"
