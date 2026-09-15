#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
install -m 0755 "$A_PROGRAM" "$A_RUNTIME_PROGRAM"
install -m 0644 "$B_INPUT_FILE" "$A_RUNTIME_INPUT"
install -d -o agentb -g agentb -m 0755 "$(dirname "$A_PIDFILE")"
install -d -o agentb -g agentb -m 0755 "$A_STATE_DIR"
rm -f "$A_STATE_DIR"/progress.json "$A_STATE_DIR"/index_events.jsonl "$A_PIDFILE"
runuser -u agentb -- /usr/bin/python3 "$A_RUNTIME_PROGRAM" --mode daemon --pidfile "$A_PIDFILE" --state-dir "$A_STATE_DIR" --input "$A_RUNTIME_INPUT" --interval 0.12 >"$RESULT_ROOT/evidence/a_stdout.log" 2>"$RESULT_ROOT/evidence/a_stderr.log" &
echo $! >"$A_LAUNCHER_FILE"
echo "A_LAUNCHER_STARTED=1"
