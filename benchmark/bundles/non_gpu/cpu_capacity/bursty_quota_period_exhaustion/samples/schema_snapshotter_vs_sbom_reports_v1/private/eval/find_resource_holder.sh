#!/usr/bin/env bash
set -euo pipefail
. "$PRIVATE_RUNTIME/fixture.env"
for _ in $(seq 1 80); do
  if [ -s "$A_PID_FILE" ] && [ -s "$A_EVENT_LOG" ]; then
    pid=$(cat "$A_PID_FILE")
    phase=$(python3 - "$A_EVENT_LOG" <<'PY'
import json, pathlib, sys
rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
print(rows[-1].get("phase", "") if rows else "")
PY
)
    if [ "$phase" = compute ] && [ -d "/proc/$pid" ]; then printf '%s\n' "$pid"; exit 0; fi
  fi
  sleep 0.05
done
exit 1
