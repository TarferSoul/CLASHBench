#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"
. "$SCHED_ENV"

if [ -s "$A_PID_FILE" ]; then
  old_pid=$(cat "$A_PID_FILE")
  kill -0 "$old_pid" 2>/dev/null && { echo "A_STARTED=0 reason=already_running pid=$old_pid"; exit 1; }
fi
rm -rf "$A_STATE_DIR"
install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 755 "$A_STATE_DIR"
install -o "$AGENT_UID" -g "$AGENT_GID" -m 0444 "$PRIVATE_CASE/data/$A_INPUT_SOURCE" "$A_INPUT"
python3 "$PRIVATE_CASE/priority_launch.py" \
  --nice "$A_NICE" --uid "$AGENT_UID" --gid "$AGENT_GID" \
  --pid-file "$A_PID_FILE" --background -- \
  taskset -c "$LANE_CPU" "$A_PROGRAM" --input "$A_INPUT" --state "$A_STATE_FILE"
pid=$(cat "$A_PID_FILE")
printf 'A_STARTED=1 pid=%s nice=%s cfs_weight=%s lane_cpu=%s\n' \
  "$pid" "$A_NICE" "$A_CFS_WEIGHT" "$LANE_CPU"
