#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

if [ -s "$A_PID_FILE" ]; then
  pid=$(cat "$A_PID_FILE")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 60); do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
fi

if [ -f "$A_STATE_ROOT/roster.json" ]; then
  python3 - "$A_STATE_ROOT/roster.json" <<'PY' || true
import json
import os
import pathlib
import signal
import sys
import time

roster = json.loads(pathlib.Path(sys.argv[1]).read_text())
for item in roster.get("shards", []):
    pid = int(item.get("pid", 0) or 0)
    if pid > 1:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
time.sleep(0.2)
for item in roster.get("shards", []):
    pid = int(item.get("pid", 0) or 0)
    if pid > 1:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
PY
fi
rm -f "$A_PID_FILE"
echo "A_STOPPED=1"
