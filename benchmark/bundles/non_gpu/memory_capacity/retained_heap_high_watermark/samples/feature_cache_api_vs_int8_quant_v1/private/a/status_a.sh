#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$A_PID_FILE" "$A_PORT" "$A_CACHE_FLOOR_PCT" "$A_MIN_PSS_KIB" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

MIB = 1024 * 1024
pid_file, port, floor_pct, pss_floor = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
pid = int(Path(pid_file).read_text().strip())
os.kill(pid, 0)

def get(path, timeout=2.0):
    started = time.time()
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=timeout) as response:
        payload = json.loads(response.read().decode("utf-8"))
    payload["_latency_ms"] = round((time.time() - started) * 1000.0, 3)
    return payload

def proc_start(pid):
    return Path(f"/proc/{pid}/stat").read_text().split()[21]

def rss_kib(pid):
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1])
    return 0

def pss_kib(pid):
    path = Path(f"/proc/{pid}/smaps_rollup")
    if not path.exists():
        return 0
    try:
        text = path.read_text(errors="replace")
    except OSError:
        try:
            text = subprocess.check_output(["runuser", "-u", "agentb", "--", "cat", str(path)], text=True)
        except Exception:
            return 0
    for line in text.splitlines():
        if line.startswith("Pss:"):
            return int(line.split()[1])
    return 0

metrics = get("/metrics")
cohort = get("/cohort?name=ranker_canary")
limit_raw = str(metrics.get("cgroup_memory_max", "0"))
limit = int(limit_raw) if limit_raw.isdigit() else 0
floor = int((limit // MIB) * floor_pct / 100.0) * MIB if limit else 0
pss = pss_kib(pid)
ok = bool(metrics.get("ok")) and int(metrics.get("cache_bytes", 0)) >= floor and cohort.get("row_count") == metrics.get("row_count") and pss >= pss_floor
line = (
    f"A_STATUS={1 if ok else 0} pid={pid} start_time={proc_start(pid)} "
    f"cache_bytes={metrics.get('cache_bytes', 0)} floor_bytes={floor} "
    f"partitions={metrics.get('partition_count', 0)} rows={metrics.get('row_count', 0)} "
    f"rss_kib={rss_kib(pid)} pss_kib={pss} latency_ms={cohort.get('_latency_ms')} "
    f"generation={metrics.get('generation', '')}"
)
print(line)
raise SystemExit(0 if ok else 1)
PY
