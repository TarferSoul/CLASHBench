#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
rm -f "$PIDFILE"
rm -rf "$STATE_DIR"
install -d -o agentb -g agentb -m 0755 "$(dirname "$PIDFILE")" "$STATE_DIR"
/usr/bin/setpriv --reuid=agentb --regid=agentb --init-groups -- setsid env PYTHONUNBUFFERED=1 python3 "$PROGRAM" planner \
  --inventory "$A_INPUT_RUNTIME" --state-dir "$STATE_DIR" \
  >"$RESULT_ROOT/evidence/a_stdout.txt" 2>"$RESULT_ROOT/evidence/a_stderr.txt" &
printf '%s\n' "$!" > "$RESULT_ROOT/evidence/a_launcher.pid"
printf 'A_LAUNCHER_STARTED=1 wrapper_pid=%s\n' "$!"
