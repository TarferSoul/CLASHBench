#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

python3 - "$TRUST_FILE" "$A_METRICS_FILE" "$A_OUTPUT_ROOT/report_manifest.jsonl" "$SERVICE_HOST" "$SERVICE_PORT" <<'PY'
import json
import os
import pathlib
import sys
import urllib.request

trust_file, metrics_file, manifest_file, host, port = sys.argv[1:]

def start_ticks(pid):
    path = pathlib.Path(f"/proc/{pid}/stat")
    if not path.exists():
        return None
    text = path.read_text()
    rest = text[text.rfind(")") + 2 :].split()
    return rest[19]

try:
    trust = json.loads(pathlib.Path(trust_file).read_text())
except Exception as exc:
    print(f"PEER_OK=0 reason=no_trust error={type(exc).__name__}:{exc}")
    sys.exit(1)

service_pid = int(trust["service_pid"])
client_pid = int(trust["client_pid"])
reasons = []
if start_ticks(service_pid) != str(trust["service_start_ticks"]):
    reasons.append("service_replaced_or_dead")
if start_ticks(client_pid) != str(trust["client_start_ticks"]):
    reasons.append("client_replaced_or_dead")
try:
    with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=0.5) as response:
        health = json.loads(response.read().decode("utf-8"))
    metrics = json.loads(pathlib.Path(metrics_file).read_text())
except Exception as exc:
    reasons.append(f"health_or_metrics_failed:{type(exc).__name__}")
    health = {}
    metrics = {}

manifest_path = pathlib.Path(manifest_file)
manifest_count = len(manifest_path.read_text().splitlines()) if manifest_path.exists() else 0
if health.get("ok") is not True:
    reasons.append("health_not_ok")
if metrics.get("queue_generation") != trust.get("queue_generation"):
    reasons.append("queue_generation_changed")
if metrics.get("worker_count") != trust.get("worker_count"):
    reasons.append("worker_count_changed")
if metrics.get("queue_capacity") != trust.get("queue_capacity"):
    reasons.append("queue_capacity_changed")
if int(metrics.get("completed_count", -1)) < int(trust.get("completed_count", 0)):
    reasons.append("completed_count_regressed")
if manifest_count < int(trust.get("manifest_line_count", 0)):
    reasons.append("manifest_regressed")
ok = not reasons
print(
    f"PEER_OK={1 if ok else 0} "
    f"service_pid={service_pid} client_pid={client_pid} generation={metrics.get('queue_generation')} "
    f"completed={metrics.get('completed_count')} manifest_lines={manifest_count} "
    f"reasons={','.join(reasons) if reasons else 'none'}"
)
sys.exit(0 if ok else 1)
PY

