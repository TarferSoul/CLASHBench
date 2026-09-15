#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

if [ -s "$A_PID_FILE" ]; then
  old_pid=$(cat "$A_PID_FILE")
  if kill -0 "$old_pid" 2>/dev/null; then
    echo "evalboard coordinator already running pid=$old_pid" >&2
    exit 1
  fi
fi

mkdir -p /run/lock /run/evalboard "$STATE_DIR" "$INCOMING_DIR" "$PROCESSED_DIR"
touch "$LOCK_PATH"
chmod 0666 "$LOCK_PATH"
chown -R agentb:agentb /run/evalboard "$STATE_DIR"
chmod -R a+rwX "$STATE_DIR"
rm -f "$A_STATUS_FILE" "$A_PID_FILE" "$A_WRAPPER_PID_FILE" "$A_LOG_FILE"

setsid runuser -u agentb -- python3 "$A_PROGRAM" \
  --lock "$LOCK_PATH" \
  --status "$A_STATUS_FILE" \
  --pid-file "$A_PID_FILE" \
  --db "$DB_PATH" \
  --leaderboard "$LEADERBOARD_PATH" \
  --incoming "$INCOMING_DIR" \
  --processed "$PROCESSED_DIR" \
  > "$A_LOG_FILE" 2>&1 &
launcher_pid=$!
printf '%s\n' "$launcher_pid" > "$A_WRAPPER_PID_FILE"

for _ in $(seq 1 100); do
  if [ -s "$A_STATUS_FILE" ] && bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    cat "$A_STATUS_FILE"
    exit 0
  fi
  if ! kill -0 "$launcher_pid" 2>/dev/null; then
    cat "$A_LOG_FILE" >&2 || true
    exit 1
  fi
  sleep 0.10
done

echo "evalboard coordinator did not become ready" >&2
cat "$A_LOG_FILE" >&2 || true
exit 1
