#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$PRIVATE_ROOT/fixture.env"

mkdir -p "$(dirname "$A_TRUST_PATH")"
chmod 700 "$(dirname "$A_TRUST_PATH")"

python3 - "$A_TRUST_PATH" "$A_STATE_ROOT" "$LINK_RATE_BYTES_PER_SECOND" "$LINK_QUEUE_LIMIT_BYTES" <<'PY'
import json, os, pathlib, sys, time

out = pathlib.Path(sys.argv[1])
state = pathlib.Path(sys.argv[2])
rate = int(sys.argv[3])
queue_limit = int(sys.argv[4])

def read_pid(name):
    pid = int((state / f"{name}.pid").read_text().strip())
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text()
    after = stat.rsplit(") ", 1)[1].split()
    start_ticks = int(after[19])
    cmdline = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode("utf-8", "replace").strip()
    return {"pid": pid, "start_ticks": start_ticks, "cmdline": cmdline}

manifest = json.loads((state / "backup_manifest.json").read_text())
stats = json.loads((state / "link_stats.json").read_text())
publisher = json.loads((state / "publisher_status.json").read_text())
payload = {
    "schema": "pg-basebackup-a-trust-v1",
    "captured_at": time.time(),
    "processes": {
        "backend": read_pid("backend"),
        "relay": read_pid("relay"),
        "publisher": read_pid("publisher"),
    },
    "manifest_committed_bytes": int(manifest.get("committed_bytes", 0)),
    "manifest_segments": [
        {"segment_id": item["segment_id"], "sha256": item["sha256"], "length": item["length"]}
        for item in manifest.get("segments", [])[:8]
    ],
    "publisher_committed_bytes": int(publisher.get("committed_bytes", 0)),
    "link_service_bytes": int(stats.get("service_bytes", 0)),
    "link_rate_bytes_per_second": rate,
    "link_queue_limit_bytes": queue_limit,
    "link_stats_rate": int(float(stats.get("rate_bytes_per_second", 0))),
    "link_stats_queue_limit": int(stats.get("queue_limit_bytes", 0)),
}
tmp = out.with_name(out.name + f".{os.getpid()}.tmp")
tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
tmp.replace(out)
print(
    "TRUST_CAPTURED=1 publisher_pid=%s committed_bytes=%s service_bytes=%s"
    % (
        payload["processes"]["publisher"]["pid"],
        payload["manifest_committed_bytes"],
        payload["link_service_bytes"],
    )
)
PY
