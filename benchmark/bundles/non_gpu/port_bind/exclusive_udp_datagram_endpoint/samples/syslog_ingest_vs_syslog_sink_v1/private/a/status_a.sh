#!/bin/bash
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}; . "$ROOT/fixture.env"
pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_PID_FILE" 2>/dev/null || true)
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || exit 1
python3 "$ROOT/data/status_probe.py" "$HOST" "$PORT" "$A_SERVICE_NAME" "$A_INSTANCE" "$A_IDENTITY_TOKEN" "$pid"
