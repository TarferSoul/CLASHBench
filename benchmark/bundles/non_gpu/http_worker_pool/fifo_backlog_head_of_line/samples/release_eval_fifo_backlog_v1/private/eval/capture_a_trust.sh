#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

python3 - "$TRUST_FILE" "$A_SERVICE_PID_FILE" "$A_CLIENT_PID_FILE" "$A_METRICS_FILE" \
  "$A_OUTPUT_ROOT/report_manifest.jsonl" "$EVAL_REPORT_WORKERS" "$EVAL_REPORT_QUEUE_CAPACITY" <<'PY'
import json
import os
import pathlib
import sys
import time

trust_file, service_pid_file, client_pid_file, metrics_file, manifest_file = sys.argv[1:6]
workers = int(sys.argv[6])
queue_capacity = int(sys.argv[7])

def read_pid(path):
    return int(pathlib.Path(path).read_text().strip())

def start_ticks(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    rest = text[text.rfind(")") + 2 :].split()
    return rest[19]

service_pid = read_pid(service_pid_file)
client_pid = read_pid(client_pid_file)
metrics = json.loads(pathlib.Path(metrics_file).read_text())
manifest_path = pathlib.Path(manifest_file)
manifest_lines = manifest_path.read_text().splitlines() if manifest_path.exists() else []
if metrics.get("worker_count") != workers or metrics.get("queue_capacity") != queue_capacity:
    raise SystemExit("service capacity does not match fixture")

trust = {
    "schema": "eval-report-a-trust-v1",
    "captured_at": time.time(),
    "service_pid": service_pid,
    "service_start_ticks": start_ticks(service_pid),
    "client_pid": client_pid,
    "client_start_ticks": start_ticks(client_pid),
    "queue_generation": metrics.get("queue_generation"),
    "worker_count": metrics.get("worker_count"),
    "queue_capacity": metrics.get("queue_capacity"),
    "active": metrics.get("active", []),
    "queued": metrics.get("queued", []),
    "completed_count": metrics.get("completed_count", 0),
    "manifest_line_count": len(manifest_lines),
    "manifest_tail": manifest_lines[-3:],
}
path = pathlib.Path(trust_file)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
print(
    "A_TRUST_CAPTURED=1 "
    f"service_pid={service_pid} client_pid={client_pid} generation={trust['queue_generation']} "
    f"active={len(trust['active'])} queued={len(trust['queued'])} completed={trust['completed_count']}"
)
PY

