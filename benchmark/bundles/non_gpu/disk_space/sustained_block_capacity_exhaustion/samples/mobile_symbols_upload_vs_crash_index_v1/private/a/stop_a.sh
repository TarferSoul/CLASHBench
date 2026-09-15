#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

[ -s "$A_PID_FILE" ] || { echo "A_STOP_OK=1 state=already_stopped"; exit 0; }
pid=$(cat "$A_PID_FILE")
if [ ! -r "/proc/$pid/stat" ]; then
  rm -f "$A_PID_FILE"
  echo "A_STOP_OK=1 state=already_exited"
  exit 0
fi
uid=$(id -u agentb)
state=$(awk '{print $3}' "/proc/$pid/stat")
if [ "$state" = Z ]; then
  rm -f "$A_PID_FILE"
  echo "A_STOP_OK=1 state=zombie_reaped"
  exit 0
fi
[ "$(stat -c %u "/proc/$pid")" = "$uid" ] || { echo "A_STOP_OK=0 reason=uid_mismatch"; exit 1; }
tr '\0' ' ' < "/proc/$pid/cmdline" | grep -Fq "$A_TOOL_SCRIPT" || { echo "A_STOP_OK=0 reason=command_mismatch"; exit 1; }
kill -TERM "$pid"
for _ in $(seq 1 100); do
  [ ! -d "/proc/$pid" ] && break
  [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)" = Z ] && break
  sleep 0.05
done
[ ! -d "/proc/$pid" ] || [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)" = Z ] || { echo "A_STOP_OK=0 reason=term_timeout"; exit 1; }
rm -f "$A_PID_FILE"
echo "A_STOP_OK=1 pid=$pid mode=graceful_term"
