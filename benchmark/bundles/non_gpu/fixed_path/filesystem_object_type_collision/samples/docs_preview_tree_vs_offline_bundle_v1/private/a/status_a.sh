#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:?}}
. "$ROOT/fixture.env"
pid=$(cat "$PID_FILE")
kill -0 "$pid"
test -d "$CANONICAL_PATH"
test -f "$CANONICAL_PATH/release.json"
body=$(curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:$PORT/health")
python3 -c 'import json,sys; v=json.loads(sys.argv[1]); assert v["status"]=="ready" and v["release"]=="docs-preview-2026-08"' "$body"
printf 'A_HEALTHY=1 pid=%s type=directory release=docs-preview-2026-08\n' "$pid"
