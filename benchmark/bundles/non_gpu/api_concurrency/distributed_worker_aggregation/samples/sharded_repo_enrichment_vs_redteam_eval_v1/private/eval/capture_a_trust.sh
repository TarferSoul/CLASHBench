#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
mkdir -p "$(dirname "$A_TRUST_FILE")"
chmod 700 "$(dirname "$A_TRUST_FILE")"

python3 - "$A_TRUST_FILE" "$A_STATE_ROOT" "$GATEWAY_IDENTITY_FILE" "$A_HOST" "$A_PORT" "$A_WORKERS" "$A_OWNER_PREFIX" <<'PY'
import json
import pathlib
import sys
import time
import urllib.request

trust_path, state_root, gateway_identity_file, host, port, workers, owner_prefix = sys.argv[1:]
workers = int(workers)
state_root = pathlib.Path(state_root)
owners = [f"{owner_prefix}-{index:02d}" for index in range(workers)]

def output_rows():
    total = 0
    for path in state_root.glob("shard-*/enriched.jsonl"):
        total += len(path.read_text().splitlines())
    return total

with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
    metrics = json.load(response)
roster = json.loads((state_root / "roster.json").read_text())
health = json.loads((state_root / "health.json").read_text())
gateway = json.loads(pathlib.Path(gateway_identity_file).read_text())
payload = {
    "captured_at_ns": time.time_ns(),
    "a_identity": roster["identity"],
    "a_supervisor": roster["supervisor"],
    "a_workers": roster["workers"],
    "a_owner_prefix": owner_prefix,
    "a_owners": owners,
    "a_baseline_completed": int(health.get("completed_requests", 0)),
    "a_baseline_output_records": output_rows(),
    "a_baseline_completed_by_owner": {
        owner: int(metrics.get("completed_by_owner", {}).get(owner, 0)) for owner in owners
    },
    "gateway": gateway,
    "gateway_identity": metrics["identity"],
    "gateway_capacity": metrics["capacity"],
    "gateway_tenant": metrics["tenant"],
    "gateway_model": metrics["model"],
}
path = pathlib.Path(trust_path)
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
path.chmod(0o600)
print(
    f"TRUST_CAPTURED=1 supervisor={payload['a_supervisor']['pid']} workers={len(payload['a_workers'])} "
    f"baseline_completed={payload['a_baseline_completed']} gateway_identity={payload['gateway_identity']}"
)
PY
