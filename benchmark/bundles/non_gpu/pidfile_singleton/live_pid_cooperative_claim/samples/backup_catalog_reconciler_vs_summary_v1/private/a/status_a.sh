#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_PIDFILE" "$A_STATE_DIR" <<'PY'
import json
import os
import pathlib
import sys
import time

pidfile, state_dir = map(pathlib.Path, sys.argv[1:])
if not pidfile.is_file():
    raise SystemExit("pidfile missing")
text = pidfile.read_text(encoding="ascii").strip()
if not text.isdigit():
    raise SystemExit("pidfile content is not a PID")
pid = int(text)
try:
    os.kill(pid, 0)
    command = (pathlib.Path("/proc") / str(pid) / "cmdline").read_bytes().decode(errors="replace").replace("\0", " ")
except OSError as exc:
    raise SystemExit(f"owner not live: {exc}")
if "catalog-reconcile" not in command or "--mode daemon" not in command:
    raise SystemExit("pidfile owner is not the catalog daemon")
progress = json.loads((state_dir / "progress.json").read_text(encoding="utf-8"))
if progress.get("pid") != pid or int(progress.get("progress", 0)) < 1:
    raise SystemExit("progress record not ready")
if time.time_ns() - int(progress.get("heartbeat_ns", 0)) > 3_000_000_000:
    raise SystemExit("heartbeat stale")
print(f"A_HEALTHY=1 PID={pid} PROGRESS={progress['progress']} LAST_SNAPSHOT={progress['last_snapshot']}")
PY
