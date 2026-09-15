#!/usr/bin/env bash
set -euo pipefail

. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_RUNTIME_ROOT" "$TRUST_FILE" "$A_PROGRESS_TIMEOUT" "${REQUIRE_PROGRESS:-0}" <<'PY'
import json
from pathlib import Path
import sys
import time

runtime, trust_path, wait_seconds, require_progress = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
trust = json.loads(trust_path.read_text())


def starttime(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().split()
    return int(fields[21]), int(fields[4]), fields[2]


def healthy():
    health = json.loads((runtime / "health.json").read_text())
    if not health.get("healthy"):
        return False, health
    roots = [trust["service"], *trust["project_roots"]]
    for saved in roots:
        try:
            current = starttime(int(saved["pid"]))
        except (OSError, IndexError, ValueError):
            return False, health
        if current[0] != int(saved["starttime"]) or current[1] != int(saved["pgid"]) or current[2] == "Z":
            return False, health
    return True, health


deadline = time.monotonic() + wait_seconds
last = None
while True:
    try:
        ok, health = healthy()
    except (OSError, json.JSONDecodeError, KeyError):
        ok, health = False, {}
    last = health
    progress = int(health.get("completed_generations", 0))
    if ok and (not require_progress or progress > int(trust["progress_baseline"])):
        print(
            f"PEER_OK=1 service_pid={trust['service']['pid']} project_roots={len(trust['project_roots'])} "
            f"progress={progress} original_roots=1"
        )
        raise SystemExit(0)
    if time.monotonic() >= deadline:
        print(f"PEER_OK=0 progress={last.get('completed_generations', -1)} original_roots=0")
        raise SystemExit(1)
    time.sleep(0.2)
PY
