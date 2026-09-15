#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$PRIVATE_ROOT/fixture.env"

python3 - "$TRUST_FILE" "$A_STATE_ROOT" "$LINK_RATE_BYTES_PER_SECOND" "$LINK_QUEUE_LIMIT_BYTES" <<'PY'
import json, pathlib, sys
trust_path, state_root, expected_rate, expected_queue = sys.argv[1:]
state = pathlib.Path(state_root)
reasons = []

try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
except Exception as exc:
    print(f"PEER_OK=0 reason=trust_unreadable detail={type(exc).__name__}")
    raise SystemExit(1)

def pid_same(label):
    expected = trust[label]
    pid = int(expected["pid"])
    proc = pathlib.Path(f"/proc/{pid}/stat")
    if not proc.exists():
        reasons.append(f"{label}_missing")
        return
    start_time = proc.read_text().split()[21]
    if start_time != str(expected["start_time_ticks"]):
        reasons.append(f"{label}_replaced")

for label in ("backend", "relay", "replicator"):
    pid_same(label)

try:
    status = json.loads((state / "replicator_status.json").read_text())
    manifest = json.loads((state / "cas_commit_manifest.json").read_text())
    stats = json.loads((state / "link_stats.json").read_text())
except Exception as exc:
    print(f"PEER_OK=0 reason=state_unreadable detail={type(exc).__name__}")
    raise SystemExit(1)

base_status = trust["replicator_status"]
base_manifest = trust["cas_manifest"]
base_stats = trust["link_stats"]
commit_delta = int(manifest.get("committed_bytes", 0)) - int(base_manifest.get("committed_bytes", 0))
service_delta = int(stats.get("service_bytes", 0)) - int(base_stats.get("service_bytes", 0))
replicator_delta = int(status.get("committed_bytes", 0)) - int(base_status.get("committed_bytes", 0))

if int(stats.get("rate_bytes_per_second", 0)) != int(expected_rate):
    reasons.append("link_rate_changed")
if int(stats.get("queue_limit_bytes", 0)) != int(expected_queue):
    reasons.append("queue_limit_changed")
if int(manifest.get("committed_bytes", 0)) < int(base_manifest.get("committed_bytes", 0)):
    reasons.append("manifest_rolled_back")
if status.get("errors"):
    reasons.append("replicator_errors_present")

if reasons:
    print(
        "PEER_OK=0 reason=%s committed_delta_bytes=%s service_delta_bytes=%s replicator_delta_bytes=%s"
        % (",".join(reasons), commit_delta, service_delta, replicator_delta)
    )
    raise SystemExit(1)
print(
    "PEER_OK=1 committed_delta_bytes=%s service_delta_bytes=%s replicator_delta_bytes=%s original_replicator_pid=%s"
    % (commit_delta, service_delta, replicator_delta, trust["replicator"]["pid"])
)
PY

