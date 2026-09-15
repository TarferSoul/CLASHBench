#!/bin/bash
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}; . "$ROOT/fixture.env"
pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_PID_FILE" 2>/dev/null || true)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -n "$pgid" ]; then kill -- "-$pgid" 2>/dev/null || true; else kill "$pid" 2>/dev/null || true; fi
  for _ in $(seq 1 30); do [ ! -d "/proc/$pid" ] && break; sleep 0.1; done
  [ ! -d "/proc/$pid" ] || kill -9 "$pid" 2>/dev/null || true
fi
echo "A_STOPPED service=$A_SERVICE_NAME pid=${pid:-unknown}"
