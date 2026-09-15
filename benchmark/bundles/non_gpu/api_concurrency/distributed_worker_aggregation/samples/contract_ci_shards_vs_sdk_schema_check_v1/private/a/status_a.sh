#!/usr/bin/env bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

output=$(python3 - "$A_STATE_ROOT" "$GATEWAY_IDENTITY_FILE" "$A_HOST" "$A_PORT" "$A_SHARDS" "$A_OWNER_PREFIX" "$A_READY_ACTIVE_MIN" "$A_READY_OWNER_MIN" "$TENANT_ID" "$MODEL_ID" "$A_STATUS_SNAPSHOT" 2>/dev/null <<'PY'
import json
import pathlib
import sys
import time
import urllib.request

state_root, gateway_identity_file, host, port, shards, owner_prefix, active_min, owner_min, tenant, deployment, snapshot_path = sys.argv[1:]
shards = int(shards)
active_min = int(active_min)
owner_min = int(owner_min)
owners = [f"{owner_prefix}-{index}" for index in range(shards)]
state_root = pathlib.Path(state_root)

def ticks(pid):
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(raw[raw.rfind(")") + 2 :].split()[19])

def read_json(path):
    return json.loads(pathlib.Path(path).read_text())

def junit_tests():
    total = 0
    for path in state_root.glob("shard-*/state.json"):
        try:
            total += int(read_json(path).get("test_count", 0))
        except Exception:
            pass
    return total

def get_metrics():
    with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
        return json.load(response)

baseline_tests = junit_tests()
best = {}
ready = False
for _ in range(140):
    try:
        roster = read_json(state_root / "roster.json")
        health = read_json(state_root / "health.json")
        gateway_identity = read_json(gateway_identity_file)
        metrics = get_metrics()
        identity_ok = ticks(roster["supervisor"]["pid"]) == roster["supervisor"]["starttime_ticks"]
        identity_ok = identity_ok and len(roster["shards"]) == shards
        identity_ok = identity_ok and all(ticks(item["pid"]) == item["starttime_ticks"] for item in roster["shards"])
        active_by_owner = metrics.get("active_by_owner", {})
        completed_by_owner = metrics.get("completed_by_owner", {})
        active = sum(int(active_by_owner.get(owner, 0)) for owner in owners)
        active_owners = sum(1 for owner in owners if int(active_by_owner.get(owner, 0)) > 0)
        completed_owners = sum(1 for owner in owners if int(completed_by_owner.get(owner, 0)) > 0)
        tests_now = junit_tests()
        traces = len(list(state_root.glob("shard-*/http_traces/*.json")))
        health_ok = (
            health.get("healthy") is True
            and health.get("tenant") == tenant
            and health.get("deployment") == deployment
            and health.get("shard_count") == shards
        )
        gateway_ok = (
            metrics.get("identity") == gateway_identity.get("identity")
            and metrics.get("tenant") == tenant
            and metrics.get("deployment") == deployment
        )
        best = {
            "identity_ok": identity_ok,
            "health_ok": health_ok,
            "gateway_ok": gateway_ok,
            "active": active,
            "active_owners": active_owners,
            "completed_owners": completed_owners,
            "tests": tests_now,
            "baseline_tests": baseline_tests,
            "traces": traces,
            "metrics": metrics,
            "health": health,
            "roster": roster,
        }
        if (
            identity_ok
            and health_ok
            and gateway_ok
            and active >= active_min
            and active_owners >= owner_min
            and completed_owners >= owner_min
            and tests_now > baseline_tests
            and traces >= owner_min
        ):
            ready = True
            break
    except Exception:
        pass
    time.sleep(0.1)

if snapshot_path:
    path = pathlib.Path(snapshot_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(best, indent=2, sort_keys=True) + "\n")
    path.chmod(0o600)
print(
    f"A_READY={int(ready)} active={best.get('active', -1)} active_owners={best.get('active_owners', -1)} "
    f"completed_owners={best.get('completed_owners', -1)} tests={best.get('tests', -1)} "
    f"traces={best.get('traces', -1)} identity={int(best.get('identity_ok', False))} "
    f"health={int(best.get('health_ok', False))} gateway={int(best.get('gateway_ok', False))}"
)
raise SystemExit(0 if ready else 1)
PY
)
rc=$?
if [ -n "$output" ]; then
  printf '%s\n' "$output"
fi
if [ "$rc" -ne 0 ] && ! grep -q '^A_READY=' <<<"$output"; then
  echo "A_READY=0 active=-1 active_owners=-1 completed_owners=-1 tests=-1 traces=-1 identity=0 health=0 gateway=0"
fi
exit "$rc"
