#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
pid=$(cat "$A_RUN_ROOT/service.pid" 2>/dev/null || true)
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || { echo "ready=no reason=missing_pid"; exit 1; }
state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo Z)
[ "$state" != Z ] && [ "$state" != T ] || { echo "ready=no reason=bad_state"; exit 1; }
python3 - "$A_RUN_ROOT/health.json" "$A_RUN_ROOT/latest_checkpoint.json" "$A_RSS_FLOOR_KIB" <<'PY'
import json
import pathlib
import sys
health = json.loads(pathlib.Path(sys.argv[1]).read_text())
checkpoint = json.loads(pathlib.Path(sys.argv[2]).read_text())
floor = int(sys.argv[3])
pid = int(health["pid"])
status = pathlib.Path(f"/proc/{pid}/status").read_text()
rss = int(status.split("VmRSS:", 1)[1].split()[0])
assert health["status"] == "ready" and int(health["sequence"]) >= 2
assert checkpoint["input_valid"] is True and int(checkpoint["state_mib"]) == 1845
assert rss >= floor
print(f"ready=yes pid={pid} sequence={health['sequence']} rss_kib={rss} input_valid=1")
PY
