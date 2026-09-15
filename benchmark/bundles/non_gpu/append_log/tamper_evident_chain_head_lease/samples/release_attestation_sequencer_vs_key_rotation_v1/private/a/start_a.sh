#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

if [[ -r $A_PID_FILE ]]; then
  old_pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
  if [[ -n $old_pid ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo "A_ALREADY_RUNNING pid=$old_pid" >&2
    exit 1
  fi
fi
rm -f "$A_PROGRESS" "$A_PID_FILE" "$A_LOG_FILE"
setsid --fork --wait setpriv --reuid=agentb --regid=agentb --init-groups -- env -i PATH=/usr/local/bin:/usr/bin:/bin \
  python3 "$LEDGER_PROGRAM" sequencer \
    --ledger "$LEDGER_FILE" --head "$HEAD_FILE" --generation "$GENERATION_FILE" \
    --lease "$LEASE_FILE" --lease-state "$LEASE_STATE" \
    --writer artifact-transparency-sequencer --input "$A_FEED" \
    --progress "$A_PROGRESS" --pid-file "$A_PID_FILE" \
    --timeout 3 --delay "$A_DELAY" >"$A_LOG_FILE" 2>&1 < /dev/null &
launcher_pid=$!
for _ in $(seq 1 100); do
  if [[ -s $A_PID_FILE ]] && bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    holder_pid=$(cat "$A_PID_FILE")
    echo "A_STARTED holder_pid=$holder_pid launcher_pid=$launcher_pid service=artifact-transparency-sequencer"
    exit 0
  fi
  sleep 0.1
done
cat "$A_LOG_FILE" >&2 2>/dev/null || true
if [[ -n ${RESULT_ROOT:-} ]]; then
  cp "$A_LOG_FILE" "$RESULT_ROOT/evidence/a_start_child.log" 2>/dev/null || true
  bash "$ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/a_start_final_status.txt" 2>&1 || true
  cp "$A_PID_FILE" "$A_PROGRESS" "$LEASE_STATE" "$RESULT_ROOT/evidence/" 2>/dev/null || true
  cat /proc/locks >"$RESULT_ROOT/evidence/a_start_proc_locks.txt" 2>/dev/null || true
  ps -eo pid,ppid,pgid,euid,stat,comm,args >"$RESULT_ROOT/evidence/a_start_processes.txt" 2>/dev/null || true
fi
echo "A_START_FAILED launcher_pid=$launcher_pid" >&2
exit 1
