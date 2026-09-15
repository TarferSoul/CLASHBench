#!/usr/bin/env bash
set -euo pipefail
command -v python3 >/dev/null
command -v runuser >/dev/null
test -x "$INSTALL_ROOT/worker_service.py"
test -x "$INSTALL_ROOT/incumbent_scheduler.py"
test -x "$INSTALL_ROOT/$B_CLIENT_FILE"
test -r "$B_REQUEST_RUNTIME"
python3 - "$PRIVATE_CASE/fixture.json" "$B_REQUEST_RUNTIME" "$SERVICE_PORT" "$POOL_SIZE" "$B_WINDOW_MS" <<'PY'
import json, sys
fixture = json.load(open(sys.argv[1]))
request = json.load(open(sys.argv[2]))
port, pool, window = map(int, sys.argv[3:])
assert fixture["worker_pool_size"] == pool == 3
assert fixture["b_contract"]["consistency_window_ms"] == window == 950
assert request["consistency_window_ms"] == window
assert request["endpoint"] == f"http://127.0.0.1:{port}/v1/render-panel"
assert len(request["sections"]) == 6 == len(set(request["sections"]))
assert request["revision"] == "release-2026.08.05"
PY
printf 'PREFLIGHT_OK=1 service=%s port=%s pool=%s\n' "$SERVICE_ID" "$SERVICE_PORT" "$POOL_SIZE"
