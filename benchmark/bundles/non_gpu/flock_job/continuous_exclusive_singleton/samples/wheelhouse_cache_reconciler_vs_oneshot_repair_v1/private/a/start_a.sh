#!/bin/bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must point at the runtime private case}"
source "$CASE_PRIVATE_ROOT/fixture.env"

if [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "A_ALREADY_RUNNING pid=$(cat "$PID_FILE")"
  exit 0
fi

rm -f "$STATUS_FILE" "$PID_FILE"
mkdir -p "$STATUS_DIR"
chown -R agentb:agentb "$STATUS_DIR" "$REPO_ROOT"
setsid runuser -u agentb -- wheelhousectl controller \
  --repo "$REPO_ROOT" \
  --incoming "$REPO_ROOT/incoming" \
  --lock "$A_LOCK_PATH" \
  --status "$STATUS_FILE" \
  --pid-file "$PID_FILE" \
  --interval 0.20 \
  > "$RESULT_ROOT/evidence/reconciler.stdout" \
  2> "$RESULT_ROOT/evidence/reconciler.stderr" &
launcher_pid=$!
printf '%s\n' "$launcher_pid" > "$STATUS_DIR/reconciler.wrapper.pid"
echo "A_STARTED launcher_pid=$launcher_pid lock=$A_LOCK_PATH user=agentb"
