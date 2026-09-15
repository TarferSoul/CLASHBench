#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$(dirname "$TRUST_FILE")"
python3 - "$A_RUNS_ROOT" "$TRUST_FILE" "$REDIS_HOST" "$REDIS_PORT" "$REDIS_DB" "$READER_OWNER_PREFIX" "$CASE_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root, trust_path, host, port, db, prefix, case_root = sys.argv[1:]
sys.path.insert(0, str(Path(case_root) / "lib"))
import redis_rwlock

r = redis_rwlock.Redis(host, int(port), int(db))
try:
    readers = []
    for state in sorted(Path(root).glob("reader_*")):
        meta = json.loads((state / "metadata.json").read_text())
        token = meta["token"]
        readers.append({"index": meta["index"], "pid": meta["pid"], "start_time": meta["start_time"], "token": token, "owner_key": prefix + token, "progress": meta["progress"], "pttl_ms": r.command("PTTL", prefix + token)})
    trust = {"captured_at": __import__("time").time(), "readers": readers, "redis": redis_rwlock.inspect_state(r)}
    Path(trust_path).write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
    print("A_TRUST_CAPTURED readers=%d file=%s" % (len(readers), trust_path))
finally:
    r.close()
PY
