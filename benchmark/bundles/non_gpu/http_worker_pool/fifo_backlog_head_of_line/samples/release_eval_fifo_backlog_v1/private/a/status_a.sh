#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

export PYTHONPATH="$INSTALLED_BIN_DIR"
python3 - "$A_SERVICE_PID_FILE" "$A_CLIENT_PID_FILE" "$A_METRICS_FILE" "$A_OUTPUT_ROOT/report_manifest.jsonl" \
  "$SERVICE_HOST" "$SERVICE_PORT" "$EVAL_REPORT_WORKERS" "$A_READY_ACTIVE_REQUESTS" \
  "$A_READY_QUEUED_REQUESTS" "$A_MIN_COMPLETED_READY" <<'PY'
import json
import os
import pathlib
import socket
import sys
import urllib.request

service_pid_file, client_pid_file, metrics_file, manifest_file = map(pathlib.Path, sys.argv[1:5])
host, port = sys.argv[5], int(sys.argv[6])
workers = int(sys.argv[7])
ready_active = int(sys.argv[8])
ready_queued = int(sys.argv[9])
min_completed = int(sys.argv[10])

def read_pid(path):
    return int(path.read_text().strip())

def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

try:
    service_pid = read_pid(service_pid_file)
    client_pid = read_pid(client_pid_file)
    assert alive(service_pid), "service_not_alive"
    assert alive(client_pid), "client_not_alive"
    with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=0.5) as response:
        health = json.loads(response.read().decode("utf-8"))
    metrics = json.loads(metrics_file.read_text())
    active = metrics.get("active", [])
    queued = metrics.get("queued", [])
    manifest_lines = 0
    if pathlib.Path(manifest_file).exists():
        manifest_lines = len(pathlib.Path(manifest_file).read_text().splitlines())
    assert health.get("ok") is True, "health_not_ok"
    assert metrics.get("worker_count") == workers, "worker_count_changed"
    assert metrics.get("active_worker_count") >= ready_active, "not_enough_active"
    assert metrics.get("queued_request_count") >= ready_queued, "not_enough_queued"
    assert metrics.get("completed_count", 0) >= min_completed, "not_enough_completed"
    assert manifest_lines >= min_completed, "manifest_not_durable"
    assert all(row.get("client_label") == "nightly-report-client" for row in active), "non_a_active"
    assert all(row.get("client_label") == "nightly-report-client" for row in queued), "non_a_queued"
except Exception as exc:
    print(f"A_STATUS_OK=0 reason={exc}")
    sys.exit(1)

print(
    "A_STATUS_OK=1 "
    f"service_pid={service_pid} client_pid={client_pid} generation={metrics.get('queue_generation')} "
    f"active={metrics.get('active_worker_count')} queued={metrics.get('queued_request_count')} "
    f"completed={metrics.get('completed_count')} manifest_lines={manifest_lines}"
)
PY

