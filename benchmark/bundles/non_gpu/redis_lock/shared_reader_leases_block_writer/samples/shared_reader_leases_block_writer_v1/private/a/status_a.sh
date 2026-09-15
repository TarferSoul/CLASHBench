#!/usr/bin/env bash
set -euo pipefail
python3 - "$A_RUNS_ROOT" "$READER_OWNER_PREFIX" "$REDIS_HOST" "$REDIS_PORT" "$REDIS_DB" "$CASE_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root, prefix, host, port, db, case_root = sys.argv[1:]
case_root = Path(case_root)
sys.path.insert(0, str(case_root / "lib"))
import redis_rwlock

r = redis_rwlock.Redis(host, int(port), int(db))
try:
    rows = []
    ready = True
    progress = 0
    for state in sorted(Path(root).glob("reader_*")):
        meta_path = state / "metadata.json"
        if not meta_path.exists():
            ready = False
            continue
        meta = json.loads(meta_path.read_text())
        progress += int(meta.get("progress", 0))
        token = meta.get("token", "")
        pttl = r.command("PTTL", prefix + token) if token else -2
        alive = Path(f"/proc/{meta.get('pid', 0)}").exists()
        row = {"index": meta.get("index"), "pid": meta.get("pid"), "token": token, "alive": alive, "ready": meta.get("ready", False), "progress": meta.get("progress", 0), "pttl_ms": pttl}
        rows.append(row)
        if not (alive and meta.get("ready") and pttl > 0):
            ready = False
    state = redis_rwlock.inspect_state(r)
    if len(rows) != 2 or state["reader_count"] < 2:
        ready = False
    print("ready=%s readers=%d progress=%d state=%s" % ("yes" if ready else "no", len(rows), progress, json.dumps({"reader_count": state["reader_count"], "writer": state["writer"]}, sort_keys=True)))
    print(json.dumps({"ready": ready, "readers": rows, "redis": state}, sort_keys=True))
finally:
    r.close()
PY
