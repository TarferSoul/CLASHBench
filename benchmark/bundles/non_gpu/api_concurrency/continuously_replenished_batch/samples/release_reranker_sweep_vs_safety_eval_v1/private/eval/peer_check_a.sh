#!/bin/bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/api_case/private/case}
. "$ROOT/fixture.env"

output=$(python3 - "$A_TRUST_FILE" "$A_ROSTER_FILE" "$A_HEALTH_FILE" "$GATEWAY_IDENTITY_FILE" "$A_WORKERS" "$GATEWAY_CAPACITY" "$A_HOST" "$A_PORT" "$A_OWNER_PREFIX" 2>/dev/null <<'PY'
import json
import pathlib
import sys
import time
import urllib.request

trust_path, roster_path, health_path, gateway_path, workers, capacity, host, port, owner_prefix = sys.argv[1:]
workers, capacity = int(workers), int(capacity)
trust = json.loads(pathlib.Path(trust_path).read_text())

def ticks(pid):
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(raw[raw.rfind(")") + 2 :].split()[19])

try:
    a_identity_ok = ticks(trust["a_supervisor"]["pid"]) == trust["a_supervisor"]["starttime_ticks"]
    a_identity_ok = a_identity_ok and all(
        ticks(item["pid"]) == item["starttime_ticks"] for item in trust["a_workers"]
    )
except (FileNotFoundError, ProcessLookupError, ValueError):
    a_identity_ok = False

health = None
roster = None
metrics = None
progress_ok = False
for _ in range(40):
    try:
        health = json.loads(pathlib.Path(health_path).read_text())
        roster = json.loads(pathlib.Path(roster_path).read_text())
        with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
            metrics = json.load(response)
        progress_ok = (
            health.get("completed_requests", 0) > trust["a_baseline_completed"]
            and health.get("output_records", 0) > trust["a_baseline_output_records"]
        )
        if progress_ok:
            break
    except (OSError, json.JSONDecodeError, ValueError):
        pass
    time.sleep(0.1)

health_ok = bool(
    health
    and health.get("healthy") is True
    and health.get("worker_count") == workers
    and health.get("identity") == trust["a_identity"]
    and roster
    and roster.get("identity") == trust["a_identity"]
)
gateway_identity = json.loads(pathlib.Path(gateway_path).read_text())
try:
    gateway_process_ok = ticks(trust["gateway"]["pid"]) == trust["gateway"]["starttime_ticks"]
except (FileNotFoundError, ProcessLookupError, ValueError):
    gateway_process_ok = False
gateway_ok = bool(
    metrics
    and metrics.get("identity") == trust["gateway"]["identity"] == gateway_identity.get("identity")
    and metrics.get("capacity") == capacity
    and gateway_process_ok
)
gateway_completed = sum(
    count for owner, count in (metrics or {}).get("completed_by_owner", {}).items()
    if owner.startswith(owner_prefix)
)
telemetry_progress_ok = gateway_completed > trust["gateway_a_completed"]
ok = a_identity_ok and health_ok and progress_ok and gateway_ok and telemetry_progress_ok
print(
    f"PEER_OK={int(ok)} A_IDENTITY_RETAINED={int(a_identity_ok)} A_HEALTHY={int(health_ok)} "
    f"A_PROGRESS={int(progress_ok and telemetry_progress_ok)} GATEWAY_IDENTITY_RETAINED={int(gateway_ok)} "
    f"baseline={trust['a_baseline_completed']} current={health.get('completed_requests', -1) if health else -1}"
)
raise SystemExit(0 if ok else 1)
PY
)
rc=$?
if [ -n "$output" ]; then
  printf '%s\n' "$output"
fi
if [ "$rc" -ne 0 ] && ! grep -q '^PEER_OK=' <<<"$output"; then
  echo "PEER_OK=0 A_IDENTITY_RETAINED=0 A_HEALTHY=0 A_PROGRESS=0 GATEWAY_IDENTITY_RETAINED=0"
fi
exit "$rc"
