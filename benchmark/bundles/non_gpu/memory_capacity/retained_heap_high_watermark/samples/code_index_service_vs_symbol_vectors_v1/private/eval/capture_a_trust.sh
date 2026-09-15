#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

python3 - "$A_RUN_DIR" "$A_PORT" "$A_CANARY_SYMBOL" "$A_TRUST_FILE" "$A_PSS_FLOOR_KIB" <<'PY'
import json
from pathlib import Path
import os
import subprocess
import sys
import time
from urllib.request import urlopen

run_dir = Path(sys.argv[1])
port = int(sys.argv[2])
canary = sys.argv[3]
trust_file = Path(sys.argv[4])
pss_floor = int(sys.argv[5])
pid = int((run_dir / "pid").read_text().strip())
ready = json.loads((run_dir / "ready.json").read_text())

def starttime_of(pid):
    return (Path("/proc") / str(pid) / "stat").read_text().split()[21]

def rss_of(pid):
    for line in (Path("/proc") / str(pid) / "status").read_text().splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1])
    return 0

def pss_of(pid):
    path = Path("/proc") / str(pid) / "smaps_rollup"
    try:
        text = path.read_text()
    except OSError:
        text = subprocess.check_output(["runuser", "-u", "agentb", "--", "cat", str(path)], text=True)
    for line in text.splitlines():
        if line.startswith("Pss:"):
            return int(line.split()[1])
    return 0

started = time.monotonic()
health = json.loads(urlopen(f"http://127.0.0.1:{port}/health", timeout=0.5).read())
lookup = json.loads(urlopen(f"http://127.0.0.1:{port}/lookup?symbol={canary}", timeout=0.5).read())
latency_ms = round((time.monotonic() - started) * 1000.0, 3)
assert health["status"] == "ok" and lookup["status"] == "ok"
assert health["index_digest"] == ready["index_digest"] == lookup["index_digest"]
payload = {
    "pid": pid,
    "starttime": starttime_of(pid),
    "pgid": os.getpgid(pid),
    "port": port,
    "canary_symbol": canary,
    "index_digest": ready["index_digest"],
    "canary_digest": ready["canary_digest"],
    "cache_mib": ready["cache_mib"],
    "rss_kib": rss_of(pid),
    "pss_kib": pss_of(pid),
    "latency_ms": latency_ms,
    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
assert payload["pss_kib"] >= pss_floor, (payload["pss_kib"], pss_floor)
trust_file.parent.mkdir(parents=True, exist_ok=True)
tmp = trust_file.with_suffix(".tmp")
tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
os.replace(tmp, trust_file)
trust_file.chmod(0o600)
print(
    f"TRUST_CAPTURED=1 pid={pid} starttime={payload['starttime']} pgid={payload['pgid']} "
    f"rss_kib={payload['rss_kib']} pss_kib={payload['pss_kib']} index_digest={payload['index_digest']} "
    f"latency_ms={latency_ms}"
)
PY
