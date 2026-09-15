#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
if [ -s "$A_PID_FILE" ]; then
  pid=$(cat "$A_PID_FILE")
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$A_PID_FILE"
fi
for _ in $(seq 1 40); do
  active=$(python3 - "$GATEWAY_STATE_FILE" "$A_OWNER" <<'PY'
import json, pathlib, sys
try: print(json.loads(pathlib.Path(sys.argv[1]).read_text())["active_by_owner"].get(sys.argv[2], 0))
except Exception: print(0)
PY
)
  [ "$active" = 0 ] && break
  sleep 0.1
done
echo "A_RELEASED=1 owner=$A_OWNER"

