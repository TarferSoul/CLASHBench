#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
pid=$(cat "$A_RUN_ROOT/service.pid" 2>/dev/null || true)
if [ -n "$pid" ]; then
  pgid=$(awk '{print $5}' "/proc/$pid/stat" 2>/dev/null || echo "$pid")
  kill -TERM -- "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
fi
[ -f "$A_RUN_ROOT/stopped.json" ] || { echo "STOP_OK=0"; exit 1; }
python3 - "$A_RUN_ROOT/stopped.json" <<'PY'
import json
import pathlib
import sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert data["status"] == "stopped" and data["graceful"] is True
print(f"STOP_OK=1 pid={data['pid']} sequence={data['sequence']}")
PY
