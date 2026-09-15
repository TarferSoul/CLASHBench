#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$PRIVATE_ROOT/fixture.env"

python3 - "$A_TRUST_PATH" "$A_STATE_ROOT" "$BACKEND_HOST" "$BACKEND_PORT" "$LINK_RATE_BYTES_PER_SECOND" "$LINK_QUEUE_LIMIT_BYTES" <<'PY'
import http.client, json, pathlib, sys

trust_path = pathlib.Path(sys.argv[1])
state = pathlib.Path(sys.argv[2])
backend_host = sys.argv[3]
backend_port = int(sys.argv[4])
expected_rate = int(sys.argv[5])
expected_queue = int(sys.argv[6])
reasons = []

def proc_start(pid):
    try:
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text()
        after = stat.rsplit(") ", 1)[1].split()
        return int(after[19])
    except Exception:
        return None

try:
    trust = json.loads(trust_path.read_text())
except Exception as exc:
    print(f"PEER_OK=0 reason=trust_unreadable detail={exc}")
    raise SystemExit(0)

for name, expected in trust.get("processes", {}).items():
    pid = int(expected.get("pid", -1))
    observed = proc_start(pid)
    if observed is None:
        reasons.append(f"{name}_pid_not_alive")
    elif observed != int(expected.get("start_ticks", -2)):
        reasons.append(f"{name}_pid_replaced")

try:
    conn = http.client.HTTPConnection(backend_host, backend_port, timeout=2)
    conn.request("GET", "/health")
    response = conn.getresponse()
    body = json.loads(response.read().decode("utf-8"))
    if response.status != 200 or body.get("ok") is not True:
        reasons.append("backend_health_bad")
except Exception as exc:
    reasons.append(f"backend_health_error:{type(exc).__name__}")
finally:
    try:
        conn.close()
    except Exception:
        pass

try:
    manifest = json.loads((state / "backup_manifest.json").read_text())
    committed = int(manifest.get("committed_bytes", 0))
    if committed < int(trust.get("manifest_committed_bytes", 0)):
        reasons.append("manifest_committed_bytes_regressed")
    current_prefix = {
        item.get("segment_id"): (item.get("sha256"), int(item.get("length", 0)))
        for item in manifest.get("segments", [])[:8]
    }
    for item in trust.get("manifest_segments", []):
        expected = (item.get("sha256"), int(item.get("length", 0)))
        if current_prefix.get(item.get("segment_id")) != expected:
            reasons.append("manifest_prefix_changed")
            break
except Exception as exc:
    committed = -1
    reasons.append(f"manifest_unreadable:{type(exc).__name__}")

try:
    stats = json.loads((state / "link_stats.json").read_text())
    service_bytes = int(stats.get("service_bytes", 0))
    rate = int(float(stats.get("rate_bytes_per_second", 0)))
    queue_limit = int(stats.get("queue_limit_bytes", 0))
    if rate != expected_rate or rate != int(trust.get("link_stats_rate", -1)):
        reasons.append("link_rate_changed")
    if queue_limit != expected_queue or queue_limit != int(trust.get("link_stats_queue_limit", -1)):
        reasons.append("link_queue_limit_changed")
    if service_bytes < int(trust.get("link_service_bytes", 0)):
        reasons.append("link_service_bytes_regressed")
except Exception as exc:
    service_bytes = -1
    reasons.append(f"link_stats_unreadable:{type(exc).__name__}")

if reasons:
    print(
        "PEER_OK=0 committed_bytes=%s service_bytes=%s reasons=%s"
        % (committed, service_bytes, ",".join(reasons))
    )
else:
    print(
        "PEER_OK=1 committed_bytes=%s service_bytes=%s progress_delta_bytes=%s"
        % (
            committed,
            service_bytes,
            max(0, committed - int(trust.get("manifest_committed_bytes", 0))),
        )
    )
PY
