#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
mkdir -p "$(dirname "$A_TRUST_FILE")"
python3 - "$A_SERVICE_PID_FILE" "$A_PRODUCER_PID_FILE" "$A_HOST" "$A_PORT" "$A_PROGRESS_FILE" "$A_METRICS_FILE" "$A_TRUST_FILE" <<'PY'
import json, os, sys, time, urllib.request
service_pid_file, producer_pid_file, host, port, progress_path, metrics_path, trust_path = sys.argv[1:]
def stat(pid_file):
    pid = int(open(pid_file, encoding="utf-8").read().strip())
    fields = open(f"/proc/{pid}/stat", encoding="utf-8").read().split()
    return {"pid": pid, "start": fields[21], "state": fields[2]}
service = stat(service_pid_file)
producer = stat(producer_pid_file)
with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=2.0) as response:
    health = json.load(response)
metrics = json.load(open(metrics_path, encoding="utf-8"))
progress = 0
if os.path.exists(progress_path):
    with open(progress_path, encoding="utf-8") as handle:
        progress = sum(1 for line in handle if '"status": 200' in line)
payload = {
    "captured_at": time.time(),
    "service_pid": service["pid"],
    "service_start": service["start"],
    "producer_pid": producer["pid"],
    "producer_start": producer["start"],
    "identity": health["identity"],
    "generation": health["generation"],
    "service": health["service"],
    "progress_before": progress,
    "completed_before": metrics.get("completed_by_source", {}).get("incumbent-index", 0),
}
with open(trust_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
print("A_TRUST_CAPTURED=1 service_pid=%d producer_pid=%d progress=%d identity=%s generation=%s" % (
    payload["service_pid"], payload["producer_pid"], progress, payload["identity"], payload["generation"]))
PY
