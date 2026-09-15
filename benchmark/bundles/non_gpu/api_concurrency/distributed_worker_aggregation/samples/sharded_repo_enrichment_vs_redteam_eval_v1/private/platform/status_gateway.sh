#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$A_HOST" "$A_PORT" "$GATEWAY_PID_FILE" "$GATEWAY_IDENTITY_FILE" "$GATEWAY_CAPACITY" "$MODEL_ID" "$TENANT_ID" <<'PY'
import json
import pathlib
import sys
import urllib.request

host, port, pid_file, identity_file, capacity, model, tenant = sys.argv[1:]
capacity = int(capacity)

def ticks(pid):
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(raw[raw.rfind(")") + 2 :].split()[19])

identity = json.loads(pathlib.Path(identity_file).read_text())
pid = int(pathlib.Path(pid_file).read_text().strip())
assert ticks(pid) == identity["starttime_ticks"]
with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=1) as response:
    health = json.load(response)
assert health["ready"] is True
assert health["identity"] == identity["identity"]
assert health["capacity"] == capacity
assert health["model"] == model
assert health["tenant"] == tenant
print(f"GATEWAY_OK=1 pid={pid} identity={health['identity']} active={health['active']} capacity={capacity}")
PY
