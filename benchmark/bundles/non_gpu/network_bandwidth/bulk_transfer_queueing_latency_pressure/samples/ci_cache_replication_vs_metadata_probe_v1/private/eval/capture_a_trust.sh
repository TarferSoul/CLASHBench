#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$PRIVATE_ROOT/fixture.env"

mkdir -p "$(dirname "$TRUST_FILE")"
chmod 700 "$(dirname "$TRUST_FILE")"

python3 - "$TRUST_FILE" "$A_STATE_ROOT" "$LINK_RATE_BYTES_PER_SECOND" "$LINK_QUEUE_LIMIT_BYTES" <<'PY'
import json, os, pathlib, sys, time
out, state_root, rate, queue_limit = sys.argv[1:]
state = pathlib.Path(state_root)

def pid_info(label):
    pid = int((state / f"{label}.pid").read_text().strip())
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return {
        "pid": pid,
        "start_time_ticks": stat[21],
        "cmdline": pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip(),
    }

def read_json(name):
    return json.loads((state / name).read_text())

payload = {
    "captured_at": time.time(),
    "backend": pid_info("backend"),
    "relay": pid_info("relay"),
    "replicator": pid_info("replicator"),
    "replicator_status": read_json("replicator_status.json"),
    "cas_manifest": read_json("cas_commit_manifest.json"),
    "link_stats": read_json("link_stats.json"),
    "rate_bytes_per_second": int(rate),
    "queue_limit_bytes": int(queue_limit),
}
path = pathlib.Path(out)
path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
os.chmod(path, 0o600)
print(
    "A_TRUST_CAPTURED=1 replicator_pid=%s committed_bytes=%s service_bytes=%s"
    % (
        payload["replicator"]["pid"],
        payload["cas_manifest"].get("committed_bytes", 0),
        payload["link_stats"].get("service_bytes", 0),
    )
)
PY

