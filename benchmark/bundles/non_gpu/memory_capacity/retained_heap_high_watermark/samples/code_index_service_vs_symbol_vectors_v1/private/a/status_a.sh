#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

python3 - "$A_RUN_DIR" "$A_PORT" "$A_RSS_FLOOR_KIB" "$A_PSS_FLOOR_KIB" "$A_CANARY_SYMBOL" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import time
from urllib.request import urlopen

run_dir = Path(sys.argv[1])
port = int(sys.argv[2])
rss_floor = int(sys.argv[3])
pss_floor = int(sys.argv[4])
canary = sys.argv[5]
pid_path = run_dir / "pid"
if not pid_path.exists():
    print("ready=no reason=pid_missing")
    raise SystemExit(1)
pid = int(pid_path.read_text().strip())
proc = Path("/proc") / str(pid)
if not proc.exists():
    print(f"ready=no reason=pid_not_alive pid={pid}")
    raise SystemExit(1)

def starttime_of(pid):
    stat = (Path("/proc") / str(pid) / "stat").read_text()
    return stat.split()[21]

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
        try:
            text = subprocess.check_output(["runuser", "-u", "agentb", "--", "cat", str(path)], text=True)
        except Exception:
            return 0
    for line in text.splitlines():
        if line.startswith("Pss:"):
            return int(line.split()[1])
    return 0

ready_path = run_dir / "ready.json"
if not ready_path.exists():
    print(f"ready=no reason=warmup_record_missing pid={pid}")
    raise SystemExit(1)
ready = json.loads(ready_path.read_text())
rss = rss_of(pid)
pss = pss_of(pid)
try:
    started = time.monotonic()
    health = json.loads(urlopen(f"http://127.0.0.1:{port}/health", timeout=0.4).read())
    lookup = json.loads(urlopen(f"http://127.0.0.1:{port}/lookup?symbol={canary}", timeout=0.4).read())
    latency_ms = round((time.monotonic() - started) * 1000.0, 3)
except Exception as exc:
    print(f"ready=no reason=http_canary_failed pid={pid} error={type(exc).__name__}")
    raise SystemExit(1)
ok = (
    health.get("status") == "ok"
    and lookup.get("status") == "ok"
    and health.get("index_digest") == ready.get("index_digest")
    and lookup.get("index_digest") == ready.get("index_digest")
    and rss >= rss_floor
    and pss >= pss_floor
)
if not ok:
    print(
        f"ready=no reason=canary_or_resident_floor pid={pid} rss_kib={rss} pss_kib={pss} "
        f"index_digest={ready.get('index_digest', '')}"
    )
    raise SystemExit(1)
print(
    f"ready=yes pid={pid} starttime={starttime_of(pid)} rss_kib={rss} pss_kib={pss} "
    f"cache_mib={ready.get('cache_mib')} index_digest={ready.get('index_digest')} "
    f"canary={canary} latency_ms={latency_ms}"
)
PY
