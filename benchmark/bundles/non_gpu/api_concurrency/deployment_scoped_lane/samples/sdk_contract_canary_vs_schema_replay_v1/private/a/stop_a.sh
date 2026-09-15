#!/usr/bin/env bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/lane_eval/private/case}
. "$ROOT/fixture.env"
pid=
if [ -r "$TRUST_FILE" ]; then
  pid=$(python3 - "$TRUST_FILE" <<'PY' 2>/dev/null || true
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text()).get("incumbent", {}).get("pid", ""))
PY
)
fi
if [ -z "$pid" ] && [ -r "$A_RUNTIME_ROOT/incumbent.pid" ]; then
  pid=$(cat "$A_RUNTIME_ROOT/incumbent.pid")
fi
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 160); do
    kill -0 "$pid" 2>/dev/null || break
    sleep .05
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
fi
echo "A_STOPPED=1 pid=${pid:-none}"
