#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

pid=""
if [ -s "$A_STATUS_FILE" ]; then
  pid=$(python3 - "$A_STATUS_FILE" <<'PY' || true
import json, sys
try:
    print(json.load(open(sys.argv[1]))["pid"])
except Exception:
    pass
PY
)
elif [ -s "$A_PID_FILE" ]; then
  pid=$(cat "$A_PID_FILE")
fi

if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
  if [[ "$cmdline" == *"evalboard-writer"* ]]; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 0.10
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
fi

rm -f "$A_PID_FILE" "$A_WRAPPER_PID_FILE"
echo "STOP_A_OK=1 pid=${pid:-none}"
