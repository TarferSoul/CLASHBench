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
assert fixture["worker_pool_size"] == pool == 4
assert fixture["b_contract"]["delivery_lease_ms"] == window == 850
assert request["delivery_lease_ms"] == window
assert request["endpoint"] == f"http://127.0.0.1:{port}/v1/deliver"
assert len(request["events"]) == 8 == len(set(request["events"]))
assert request["revision"] == "dispatcher-2026.08.05.2"
PY
printf 'PREFLIGHT_OK=1 service=%s port=%s pool=%s\n' "$SERVICE_ID" "$SERVICE_PORT" "$POOL_SIZE"
