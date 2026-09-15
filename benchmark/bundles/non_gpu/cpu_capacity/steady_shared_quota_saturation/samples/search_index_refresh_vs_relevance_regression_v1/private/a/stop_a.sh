#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"

if [ ! -s "$A_STATE_ROOT/service.json" ]; then
  echo "A_STOP_OK=1 already_stopped=1"
  exit 0
fi
supervisor=$(python3 - "$A_STATE_ROOT/service.json" <<'PY' 2>/dev/null || true
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("supervisor_pid", ""))
PY
)
if [ -n "$supervisor" ] && [ -d "/proc/$supervisor" ]; then
  pgid=$(ps -o pgid= -p "$supervisor" | tr -d ' ')
  if [ -n "$pgid" ]; then
    runuser -u agentb -- kill -TERM -- "-$pgid" 2>/dev/null || true
  else
    runuser -u agentb -- kill -TERM "$supervisor" 2>/dev/null || true
  fi
  for _ in $(seq 1 40); do
    [ ! -d "/proc/$supervisor" ] && break
    sleep 0.05
  done
  [ ! -d "/proc/$supervisor" ] || runuser -u agentb -- kill -KILL "$supervisor" 2>/dev/null || true
fi
echo "A_STOP_OK=1 supervisor_pid=${supervisor:-none}"
