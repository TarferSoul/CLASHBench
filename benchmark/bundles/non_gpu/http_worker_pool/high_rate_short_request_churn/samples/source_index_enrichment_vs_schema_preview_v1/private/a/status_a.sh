#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
python3 - "$A_SERVICE_PID_FILE" "$A_PRODUCER_PID_FILE" "$A_HOST" "$A_PORT" "$A_SERVICE_NAME" "$A_PROGRESS_FILE" "$A_READY_MIN_COMPLETIONS" "$A_METRICS_FILE" <<'PY'
import json, os, sys, urllib.request
service_pid_file, producer_pid_file, host, port, service, progress_path, min_done, metrics_path = sys.argv[1:]
min_done = int(min_done)
def alive(pid_file):
    try:
        pid = int(open(pid_file, encoding="utf-8").read().strip())
        with open(f"/proc/{pid}/stat", encoding="utf-8") as handle:
            stat = handle.read().split()
        return pid, stat[2] != "Z"
    except Exception:
        return None, False
service_pid, service_alive = alive(service_pid_file)
producer_pid, producer_alive = alive(producer_pid_file)
with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=2.0) as response:
    health = json.load(response)
metrics = json.load(open(metrics_path, encoding="utf-8")) if os.path.exists(metrics_path) else {}
progress = 0
if os.path.exists(progress_path):
    with open(progress_path, encoding="utf-8") as handle:
        progress = sum(1 for line in handle if '"status": 200' in line)
queue_depth = int(metrics.get("queue_depth") or 0)
max_active = int(metrics.get("max_active") or 0)
ok = (
    service_alive and producer_alive and
    health.get("ready") is True and health.get("service") == service and
    progress >= min_done and max_active >= int(metrics.get("workers", 2))
)
print("A_STATUS_OK=%d service_pid=%s producer_pid=%s progress=%d queue_depth=%d active=%s max_active=%d identity=%s generation=%s" % (
    int(ok), service_pid, producer_pid, progress, queue_depth, metrics.get("active"), max_active,
    health.get("identity"), health.get("generation")))
raise SystemExit(0 if ok else 1)
PY
