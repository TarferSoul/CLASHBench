#!/usr/bin/env bash
set -euo pipefail
root=${CASE_PRIVATE_ROOT:?}
. "$root/fixture.env"
if [ -s "$A_PID_FILE" ]; then
  pid=$(cat "$A_PID_FILE")
  runuser -u "${AGENT_USER:-agentb}" -- kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || break
    state=$(ps -o stat= -p "$pid" 2>/dev/null || true)
    case "$state" in Z*) break ;; esac
    sleep 0.05
  done
fi
if [ -s "$A_STATE_ROOT/launcher.pid" ]; then
  launcher_pid=$(cat "$A_STATE_ROOT/launcher.pid")
  kill "$launcher_pid" 2>/dev/null || true
fi
echo 'A_STOPPED=1 workload=transcript_indexer'
