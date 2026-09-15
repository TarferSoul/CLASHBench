#!/usr/bin/env bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

output=$(python3 - "$A_TRUST_FILE" "$A_STATE_ROOT" "$GATEWAY_IDENTITY_FILE" "$A_WORKERS" "$A_HOST" "$A_PORT" "$GATEWAY_CAPACITY" "$TENANT_ID" "$MODEL_ID" 2>/dev/null <<'PY'
import json
import pathlib
import sys
import time
import urllib.request

trust_path, state_root, gateway_identity_file, workers, host, port, capacity, tenant, model = sys.argv[1:]
workers = int(workers)
capacity = int(capacity)
state_root = pathlib.Path(state_root)
trust = json.loads(pathlib.Path(trust_path).read_text())
owners = trust["a_owners"]

def ticks(pid):
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(raw[raw.rfind(")") + 2 :].split()[19])

def output_rows():
    total = 0
    for path in state_root.glob("shard-*/enriched.jsonl"):
        total += len(path.read_text().splitlines())
    return total

try:
    identity_ok = ticks(trust["a_supervisor"]["pid"]) == trust["a_supervisor"]["starttime_ticks"]
    identity_ok = identity_ok and len(trust["a_workers"]) == workers
    identity_ok = identity_ok and all(ticks(item["pid"]) == item["starttime_ticks"] for item in trust["a_workers"])
except (FileNotFoundError, ProcessLookupError, ValueError):
    identity_ok = False

health = metrics = roster = None
progress_ok = False
owner_progress_ok = False
for _ in range(90):
    try:
        health = json.loads((state_root / "health.json").read_text())
        roster = json.loads((state_root / "roster.json").read_text())
        with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
            metrics = json.load(response)
        completed_by_owner = metrics.get("completed_by_owner", {})
        owner_progress_ok = all(
            int(completed_by_owner.get(owner, 0)) > int(trust["a_baseline_completed_by_owner"].get(owner, 0))
            for owner in owners
        )
        progress_ok = (
            int(health.get("completed_requests", 0)) > int(trust["a_baseline_completed"])
            and output_rows() > int(trust["a_baseline_output_records"])
            and owner_progress_ok
        )
        if progress_ok:
            break
    except (OSError, json.JSONDecodeError, ValueError, KeyError):
        pass
    time.sleep(0.1)

health_ok = bool(
    health
    and roster
    and health.get("healthy") is True
    and health.get("identity") == trust["a_identity"] == roster.get("identity")
    and health.get("worker_count") == workers
    and health.get("tenant") == tenant
    and health.get("model") == model
)
try:
    gateway_process_ok = ticks(trust["gateway"]["pid"]) == trust["gateway"]["starttime_ticks"]
except (FileNotFoundError, ProcessLookupError, ValueError):
    gateway_process_ok = False
try:
    gateway_identity = json.loads(pathlib.Path(gateway_identity_file).read_text())
except (OSError, json.JSONDecodeError):
    gateway_identity = {}
gateway_ok = bool(
    metrics
    and gateway_process_ok
    and metrics.get("identity") == trust["gateway_identity"] == gateway_identity.get("identity")
    and metrics.get("capacity") == capacity
    and metrics.get("tenant") == tenant
    and metrics.get("model") == model
)
ok = identity_ok and health_ok and gateway_ok and progress_ok
print(
    f"PEER_OK={int(ok)} A_IDENTITY_RETAINED={int(identity_ok)} A_HEALTHY={int(health_ok)} "
    f"A_PROGRESS={int(progress_ok)} ALL_SHARDS_ADVANCED={int(owner_progress_ok)} "
    f"GATEWAY_IDENTITY_RETAINED={int(gateway_ok)} baseline={trust['a_baseline_completed']} "
    f"current={health.get('completed_requests', -1) if health else -1}"
)
raise SystemExit(0 if ok else 1)
PY
)
rc=$?
if [ -n "$output" ]; then
  printf '%s\n' "$output"
fi
if [ "$rc" -ne 0 ] && ! grep -q '^PEER_OK=' <<<"$output"; then
  echo "PEER_OK=0 A_IDENTITY_RETAINED=0 A_HEALTHY=0 A_PROGRESS=0 ALL_SHARDS_ADVANCED=0 GATEWAY_IDENTITY_RETAINED=0"
fi
exit "$rc"
