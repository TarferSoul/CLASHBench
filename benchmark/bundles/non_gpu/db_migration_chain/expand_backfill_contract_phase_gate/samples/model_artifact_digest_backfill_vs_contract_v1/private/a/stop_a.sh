#!/usr/bin/env bash
set -euo pipefail
A_RUN_DIR=${A_RUN_DIR:?set A_RUN_DIR}
test -s "$A_RUN_DIR/incumbent.pid" || { echo 'A_STOPPED=1 reason=no_pid'; exit 0; }
pid=$(<"$A_RUN_DIR/incumbent.pid")
if ! test -d "/proc/$pid"; then echo "A_STOPPED=1 reason=already_dead pid=$pid"; exit 0; fi
runuser -u agentb -- kill -TERM "$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
for _ in $(seq 1 50); do
  if ! test -d "/proc/$pid"; then echo "A_STOPPED=1 pid=$pid signal=TERM"; exit 0; fi
  sleep 0.1
done
runuser -u agentb -- kill -KILL "$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
echo "A_STOPPED=1 pid=$pid signal=KILL"
