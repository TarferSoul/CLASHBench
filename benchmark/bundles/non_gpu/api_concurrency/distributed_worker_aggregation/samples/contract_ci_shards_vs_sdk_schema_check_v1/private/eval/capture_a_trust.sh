#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
mkdir -p "$(dirname "$A_TRUST_FILE")"
chmod 700 "$(dirname "$A_TRUST_FILE")"

python3 - "$A_TRUST_FILE" "$A_STATE_ROOT" "$GATEWAY_IDENTITY_FILE" "$A_HOST" "$A_PORT" "$A_SHARDS" "$A_OWNER_PREFIX" <<'PY'
import json
import pathlib
import sys
import time
import urllib.request

trust_path, state_root, gateway_identity_file, host, port, shards, owner_prefix = sys.argv[1:]
shards = int(shards)
state_root = pathlib.Path(state_root)
owners = [f"{owner_prefix}-{index}" for index in range(shards)]

def read_json(path):
    return json.loads(pathlib.Path(path).read_text())

def trace_count():
    return len(list(state_root.glob("shard-*/http_traces/*.json")))

with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
    metrics = json.load(response)
roster = read_json(state_root / "roster.json")
health = read_json(state_root / "health.json")
gateway = read_json(gateway_identity_file)
payload = {
    "captured_at_ns": time.time_ns(),
    "a_identity": roster["identity"],
    "a_supervisor": roster["supervisor"],
    "a_shards": roster["shards"],
    "a_owner_prefix": owner_prefix,
    "a_owners": owners,
    "a_baseline_completed": int(health.get("completed_requests", 0)),
    "a_baseline_tests": int(health.get("test_count", 0)),
    "a_baseline_traces": trace_count(),
    "a_baseline_completed_by_owner": {
        owner: int(metrics.get("completed_by_owner", {}).get(owner, 0)) for owner in owners
    },
    "gateway": gateway,
    "gateway_identity": metrics["identity"],
    "gateway_capacity": metrics["capacity"],
    "gateway_tenant": metrics["tenant"],
    "gateway_deployment": metrics["deployment"],
}
path = pathlib.Path(trust_path)
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
path.chmod(0o600)
print(
    f"TRUST_CAPTURED=1 supervisor={payload['a_supervisor']['pid']} shards={len(payload['a_shards'])} "
    f"baseline_completed={payload['a_baseline_completed']} baseline_tests={payload['a_baseline_tests']} "
    f"gateway_identity={payload['gateway_identity']}"
)
PY
