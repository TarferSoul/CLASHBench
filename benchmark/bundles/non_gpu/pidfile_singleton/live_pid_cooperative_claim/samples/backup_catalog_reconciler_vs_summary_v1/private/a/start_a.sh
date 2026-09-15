#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
mkdir -p "$A_STATE_DIR" "$(dirname "$A_PIDFILE")" "$(dirname "$A_RUNTIME_QUEUE")" "$(dirname "$A_RUNTIME_PROGRAM")"
install -m 755 "$A_PROGRAM" "$A_RUNTIME_PROGRAM"
install -m 644 "$A_QUEUE_FILE" "$A_RUNTIME_QUEUE"
runuser -u "${AGENT_USER:?}" -- python3 "$A_RUNTIME_PROGRAM" --mode daemon --pidfile "$A_PIDFILE" --state-dir "$A_STATE_DIR" \
  --queue "$A_RUNTIME_QUEUE" --interval 0.18 \
  >"$RESULT_ROOT/evidence/a_stdout.log" 2>"$RESULT_ROOT/evidence/a_stderr.log" &
echo $! > "$A_LAUNCHER_FILE"
echo "A_LAUNCHER_PID=$!"
