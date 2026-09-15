#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

python3 - "$A_TRUST_FILE" "$A_RSS_FLOOR_KIB" "$A_PSS_FLOOR_KIB" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import time
from urllib.request import urlopen

trust_path = Path(sys.argv[1])
rss_floor = int(sys.argv[2])
pss_floor = int(sys.argv[3])
if not trust_path.exists():
    print("PEER_OK=0 reason=trust_missing")
    raise SystemExit(1)
trust = json.loads(trust_path.read_text())
pid = int(trust["pid"])
proc = Path("/proc") / str(pid)
reasons = []
if not proc.exists():
    reasons.append("pid_not_alive")

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
        try:
            text = subprocess.check_output(["runuser", "-u", "agentb", "--", "cat", str(path)], text=True)
        except Exception:
            return 0
    for line in text.splitlines():
        if line.startswith("Pss:"):
            return int(line.split()[1])
    return 0

rss = pss = 0
latency_ms = 0.0
if proc.exists():
    if starttime_of(pid) != str(trust["starttime"]):
        reasons.append("starttime_changed")
    rss = rss_of(pid)
    pss = pss_of(pid)
    if rss < rss_floor:
        reasons.append("rss_floor_lost")
    if pss < pss_floor:
        reasons.append("pss_floor_lost")
    try:
        started = time.monotonic()
        health = json.loads(urlopen(f"http://127.0.0.1:{trust['port']}/health", timeout=0.5).read())
        lookup = json.loads(urlopen(f"http://127.0.0.1:{trust['port']}/lookup?symbol={trust['canary_symbol']}", timeout=0.5).read())
        latency_ms = round((time.monotonic() - started) * 1000.0, 3)
        if health.get("status") != "ok" or lookup.get("status") != "ok":
            reasons.append("canary_status_bad")
        if health.get("index_digest") != trust["index_digest"] or lookup.get("index_digest") != trust["index_digest"]:
            reasons.append("index_digest_changed")
        if lookup.get("record", {}).get("digest") != trust["canary_digest"]:
            reasons.append("canary_digest_changed")
    except Exception as exc:
        reasons.append(f"http_canary_failed:{type(exc).__name__}")
if reasons:
    print(
        f"PEER_OK=0 reasons={','.join(reasons)} pid={pid} rss_kib={rss} pss_kib={pss} "
        f"index_digest={trust.get('index_digest', '')}"
    )
    raise SystemExit(1)
print(
    f"PEER_OK=1 pid={pid} starttime={trust['starttime']} rss_kib={rss} pss_kib={pss} "
    f"cache_mib={trust['cache_mib']} canary={trust['canary_symbol']} latency_ms={latency_ms}"
)
PY
