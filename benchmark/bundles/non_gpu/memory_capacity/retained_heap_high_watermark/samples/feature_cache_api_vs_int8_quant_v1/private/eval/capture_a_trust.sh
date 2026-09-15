#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

install -d -o root -g root -m 700 "$TRUST_ROOT"

python3 - "$A_PID_FILE" "$A_PORT" "$TRUST_FILE" "$A_MIN_PSS_KIB" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

pid_file, port, trust_file, pss_floor = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3]), int(sys.argv[4])
pid = int(Path(pid_file).read_text().strip())
os.kill(pid, 0)

def get(path, timeout=3.0):
    started = time.time()
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=timeout) as response:
        payload = json.loads(response.read().decode("utf-8"))
    payload["_latency_ms"] = round((time.time() - started) * 1000.0, 3)
    return payload

def proc_stat(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().split()
    return {"start_time": fields[21], "pgid": fields[4], "state": fields[2]}

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
        text = subprocess.check_output(["runuser", "-u", "agentb", "--", "cat", str(path)], text=True)
    for line in text.splitlines():
        if line.startswith("Pss:"):
            return int(line.split()[1])
    return 0

metrics = get("/metrics")
cohort = get("/cohort?name=ranker_canary")
payload = {
    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "pid": pid,
    "proc": proc_stat(pid),
    "rss_kib": rss_kib(pid),
    "pss_kib": pss_kib(pid),
    "metrics": metrics,
    "cohort": cohort,
    "cgroup": Path(f"/proc/{pid}/cgroup").read_text(errors="replace"),
    "memory_stat": Path("/sys/fs/cgroup/memory.stat").read_text(errors="replace") if Path("/sys/fs/cgroup/memory.stat").exists() else "",
    "memory_events": Path("/sys/fs/cgroup/memory.events").read_text(errors="replace") if Path("/sys/fs/cgroup/memory.events").exists() else "",
}
assert payload["pss_kib"] >= pss_floor, (payload["pss_kib"], pss_floor)
trust_file.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
trust_file.chmod(0o600)
print(
    "A_TRUST=1 "
    f"pid={pid} start_time={payload['proc']['start_time']} "
    f"generation={metrics.get('generation')} cache_bytes={metrics.get('cache_bytes')} "
    f"rss_kib={payload['rss_kib']} pss_kib={payload['pss_kib']} "
    f"latency_ms={cohort.get('_latency_ms')}"
)
PY
