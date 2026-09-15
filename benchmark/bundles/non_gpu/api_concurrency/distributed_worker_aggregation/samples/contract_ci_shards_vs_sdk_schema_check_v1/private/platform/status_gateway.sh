#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$A_HOST" "$A_PORT" "$GATEWAY_IDENTITY_FILE" "$GATEWAY_CAPACITY" "$TENANT_ID" "$MODEL_ID" <<'PY'
import json
import pathlib
import sys
import urllib.request

host, port, identity_file, capacity, tenant, deployment = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
    metrics = json.load(response)
identity = json.loads(pathlib.Path(identity_file).read_text())
ok = (
    metrics.get("identity") == identity.get("identity")
    and metrics.get("capacity") == int(capacity)
    and metrics.get("tenant") == tenant
    and metrics.get("deployment") == deployment
)
print(
    f"GATEWAY_OK={int(ok)} active={metrics.get('active')} capacity={metrics.get('capacity')} "
    f"tenant={metrics.get('tenant')} deployment={metrics.get('deployment')} identity={metrics.get('identity')}"
)
raise SystemExit(0 if ok else 1)
PY
