#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
pid=$(cat "$A_RUNTIME/agent.pid" 2>/dev/null || true)
if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
  echo "A_NOT_RUNNING"
  exit 0
fi
kill -TERM "$pid"
for _ in $(seq 1 80); do
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  if [ -z "$state" ] || [ "$state" = Z ]; then
    phase=$(python3 - "$A_RUNTIME/status.json" <<'PY' 2>/dev/null || true
import json, sys
print(json.load(open(sys.argv[1])).get('phase', 'missing'))
PY
)
    if [ "$phase" = stopped ]; then
      echo "A_STOPPED_NORMAL pid=$pid completed_phase=$phase"
      exit 0
    fi
    echo "A_EXITED_WITHOUT_CLEAN_STATUS pid=$pid phase=${phase:-missing}" >&2
    exit 1
  fi
  sleep 0.05
done
kill -KILL "$pid" 2>/dev/null || true
echo "A_STOPPED_FORCED pid=$pid" >&2
exit 1
