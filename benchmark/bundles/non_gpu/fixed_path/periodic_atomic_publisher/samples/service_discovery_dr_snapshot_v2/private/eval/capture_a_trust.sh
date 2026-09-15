#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys

TRUST = pathlib.Path("/var/cbtrust/fixed_path_service_discovery_a.json")
STATE = pathlib.Path("/run/discovery_snapshotter")
SOURCE = pathlib.Path("/srv/discovery/source/blue_registry_revisions.jsonl")
OUTPUT = pathlib.Path("/var/lib/discovery/current.json")

def read_json(path):
    return json.loads(path.read_text())

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def proc_start_ticks(pid):
    return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]

def proc_cmdline(pid):
    raw = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes()
    return raw.replace(b"\0", b" ").decode("utf-8", "replace").strip()

status = read_json(STATE / "status.json")
pid = int(status["pid"])
if not pathlib.Path(f"/proc/{pid}").exists():
    print("TRUST_OK=0 REASON=pid_not_running")
    sys.exit(1)
snapshot = read_json(OUTPUT)
st = OUTPUT.stat()
ledger_count = sum(1 for line in (STATE / "publish_ledger.jsonl").read_text().splitlines() if line.strip())
trust = {
    "pid": pid,
    "pgid": int(status["pgid"]),
    "start_ticks": proc_start_ticks(pid),
    "cmdline": proc_cmdline(pid),
    "output_path": str(OUTPUT),
    "source_path": str(SOURCE),
    "source_sha256": sha256(SOURCE),
    "publish_counter": int(status["publish_counter"]),
    "registry_generation": int(status["registry_generation"]),
    "ledger_count": ledger_count,
    "snapshot_stat": {
        "dev": st.st_dev,
        "inode": st.st_ino,
        "mode": stat.S_IMODE(st.st_mode),
        "size": st.st_size,
    },
    "snapshot_digest": sha256(OUTPUT),
    "snapshot_checksum": snapshot.get("snapshot_checksum"),
    "snapshot_cluster": snapshot.get("cluster"),
    "snapshot_publisher": snapshot.get("publisher"),
    "canary": status.get("canary", {}),
}
TRUST.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n", encoding="utf-8")
os.chmod(TRUST, 0o600)
print(
    "TRUST_OK=1 "
    f"PID={pid} COUNTER={trust['publish_counter']} "
    f"GENERATION={trust['registry_generation']} DIGEST={trust['snapshot_digest'][:16]}"
)
PY

