#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
if [ -s "$A_STATE_FILE" ]; then
  pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_STATE_FILE" 2>/dev/null || true)
  if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || true; fi
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
fi
echo "SEGMENTER_STOPPED=1"
