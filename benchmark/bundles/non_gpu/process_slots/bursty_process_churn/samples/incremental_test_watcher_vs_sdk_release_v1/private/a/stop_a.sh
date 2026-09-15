#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
if [[ -s $A_PARENT_PID_PATH ]]; then
  pid=$(<"$A_PARENT_PID_PATH")
  if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; fi
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  kill -KILL -- "-$pid" 2>/dev/null || true
  kill -KILL "$pid" 2>/dev/null || true
fi
if [[ -s $A_RUNTIME_ROOT/launcher.pid ]]; then launcher=$(<"$A_RUNTIME_ROOT/launcher.pid"); wait "$launcher" 2>/dev/null || true; fi
echo "A_STOPPED=1 service=$A_SERVICE_NAME"
