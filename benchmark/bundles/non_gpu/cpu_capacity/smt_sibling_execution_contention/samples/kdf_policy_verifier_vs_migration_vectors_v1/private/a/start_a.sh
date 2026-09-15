#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$TOPOLOGY_ENV"
if [ -s "$A_PID_FILE" ]; then
  old_pid=$(<"$A_PID_FILE")
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo "A_START_OK=0 reason=already_running pid=$old_pid"; exit 1
  fi
fi
rm -f "$A_STATE_ROOT/status.json" "$A_STATE_ROOT/unit_ledger.jsonl" "$A_STATE_ROOT/service.log"
setsid taskset -c "$A_CPU" setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --init-groups \
  "$A_PROGRAM" --state-root "$A_STATE_ROOT" --input-root "$A_INPUT_ROOT" \
  --artifact-root "$A_ARTIFACT_ROOT" --work-factor "$A_WORK_FACTOR" \
  >"$A_STATE_ROOT/service.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$A_PID_FILE"
chmod 600 "$A_PID_FILE"
sleep 0.1
kill -0 "$pid" 2>/dev/null || { cat "$A_STATE_ROOT/service.log" >&2 || true; echo "A_START_OK=0 reason=early_exit"; exit 1; }
[ "$(stat -c %u "/proc/$pid")" = "$AGENT_UID" ] || { echo "A_START_OK=0 reason=wrong_uid"; exit 1; }
echo "A_START_OK=1 pid=$pid cpu=$A_CPU uid=$AGENT_UID policy=$PLACEMENT_POLICY_ID"
