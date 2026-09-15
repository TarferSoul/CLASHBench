#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/api_case/private/case}
. "$ROOT/fixture.env"

test -s "$GATEWAY_PID_FILE"
pid=$(cat "$GATEWAY_PID_FILE")
kill -0 "$pid"
python3 - "$A_HOST" "$A_PORT" "$GATEWAY_IDENTITY_FILE" "$GATEWAY_SERVICE" "$GATEWAY_CAPACITY" "$MODEL_ID" <<'PY'
import json
import pathlib
import sys
import urllib.request

host, port, identity_path, service, capacity, model = sys.argv[1:]
capacity = int(capacity)
identity = json.loads(pathlib.Path(identity_path).read_text())
with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=1) as response:
    health = json.load(response)
assert health["ready"] is True and health["service"] == service
assert health["capacity"] == capacity and health["model"] == model
assert health["identity"] == identity["identity"]
print(
    f"GATEWAY_HEALTHY=1 pid={identity['pid']} identity={identity['identity']} "
    f"active={health['active']} completed={sum(health['completed_by_owner'].values())}"
)
PY
