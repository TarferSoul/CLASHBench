#!/usr/bin/env bash
set -euo pipefail
python3 - "$TRUST_FILE" "$REDIS_HOST" "$REDIS_PORT" "$REDIS_DB" "$ACTIVE_KEY" "$READER_OWNER_PREFIX" "$A_RUNS_ROOT" "$CASE_ROOT" <<'PY'
import json
import sys
from pathlib import Path

trust_path, host, port, db, active_key, prefix, runs, case_root = sys.argv[1:]
sys.path.insert(0, str(Path(case_root) / "lib"))
import redis_rwlock

def start_tick(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().split()[21]
    except (OSError, IndexError):
        return ""

try:
    trust = json.loads(Path(trust_path).read_text())
except (OSError, ValueError) as exc:
    print(f"PEER_OK=0 trust_unreadable={exc}")
    raise SystemExit(1)
r = redis_rwlock.Redis(host, int(port), int(db))
bad = []
try:
    for row in trust["readers"]:
        pid = int(row["pid"])
        if not Path(f"/proc/{pid}").exists():
            bad.append(f"pid_dead:{pid}")
            continue
        if start_tick(pid) != row["start_time"]:
            bad.append(f"pid_replaced:{pid}")
        if r.command("GET", row["owner_key"]) != row["token"]:
            bad.append(f"owner_missing:{row['token']}")
        if r.command("PTTL", row["owner_key"]) <= 0:
            bad.append(f"lease_expired:{row['token']}")
        meta_path = Path(runs) / f"reader_{row['index']}" / "metadata.json"
        if meta_path.exists() and json.loads(meta_path.read_text()).get("progress", 0) < row["progress"]:
            bad.append(f"progress_regressed:{row['index']}")
    active = r.command("GET", active_key)
    state = redis_rwlock.inspect_state(r)
    if state["reader_count"] < len(trust["readers"]):
        bad.append("reader_set_shrank")
    if bad:
        print("PEER_OK=0 " + ";".join(bad))
        raise SystemExit(1)
    print("PEER_OK=1 readers=%d active=%s reader_set=%d" % (len(trust["readers"]), active, state["reader_count"]))
finally:
    r.close()
PY
