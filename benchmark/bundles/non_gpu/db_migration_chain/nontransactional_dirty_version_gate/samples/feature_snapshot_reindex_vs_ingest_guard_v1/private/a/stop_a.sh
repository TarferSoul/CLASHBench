#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}; . "$ROOT/fixture.env"
if [ ! -s "$A_STATE_FILE" ]; then echo 'A_STOPPED=1 reason=no_state'; exit 0; fi
read -r pid pgid ticks < <(python3 - "$A_STATE_FILE" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding='utf-8')); print(x['pid'],x['pgid'],x['process_start_ticks'])
PY
)
if [ -r "/proc/$pid/stat" ] && [ "$(awk '{print $22}' "/proc/$pid/stat")" = "$ticks" ]; then
  kill -TERM -- "-$pgid" 2>/dev/null || true
  for _ in $(seq 1 50); do state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo absent); [ "$state" = absent ] || [ "$state" = Z ] && break; sleep 0.1; done
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo absent); [ "$state" = absent ] || [ "$state" = Z ] || kill -KILL -- "-$pgid" 2>/dev/null || true
fi
echo "A_STOPPED=1 pid=$pid pgid=$pgid"
