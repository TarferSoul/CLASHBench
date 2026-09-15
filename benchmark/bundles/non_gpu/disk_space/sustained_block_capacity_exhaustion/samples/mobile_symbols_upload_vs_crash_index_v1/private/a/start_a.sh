#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

if [ -s "$A_PID_FILE" ] && kill -0 "$(cat "$A_PID_FILE")" 2>/dev/null; then
  echo "A_START_OK=0 reason=already_running"
  exit 1
fi
[ ! -e "$A_OUTPUT_DIR" ] || { echo "A_START_OK=0 reason=output_exists"; exit 1; }
install -d -m 0755 -o agentb -g agentb "$A_RUNTIME_DIR"
install -d -m 0700 "$(dirname "$A_PID_FILE")"
: > "$A_LOG_FILE"
chown agentb:agentb "$A_LOG_FILE"
uid=$(id -u agentb)
gid=$(id -g agentb)
setsid setpriv --reuid="$uid" --regid="$gid" --init-groups \
  /usr/bin/python3 "$A_TOOL_SCRIPT" \
    --output "$A_OUTPUT_DIR" --runtime "$A_RUNTIME_DIR" \
    --total-bytes "$A_PAYLOAD_BYTES" --files "$A_FILE_COUNT" \
    >>"$A_LOG_FILE" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$A_PID_FILE"
chmod 600 "$A_PID_FILE"
for _ in $(seq 1 20); do
  [ -d "/proc/$pid" ] && break
  sleep 0.05
done
[ -d "/proc/$pid" ] || { echo "A_START_OK=0 reason=process_missing"; exit 1; }
[ "$(stat -c %u "/proc/$pid")" = "$uid" ] || { echo "A_START_OK=0 reason=wrong_uid"; exit 1; }
echo "A_START_OK=1 pid=$pid uid=$uid process=$A_PROCESS_LABEL"
