#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
pid=$(cat "$A_PID_FILE")
python3 - "$pid" "$A_READY_FILE" "$A_PROGRESS_FILE" "$A_OUTPUT_ROOT" "$A_TRUST_FILE" "$AGENT_UID" "$A_RESULT_FILES" <<'PY'
import hashlib
import json
import pathlib
import sys

pid, ready_path, progress_path, root_path, trust_path, expected_uid, results = sys.argv[1:]
proc = pathlib.Path(f"/proc/{pid}")
stat = (proc / "stat").read_text().split()
if proc.stat().st_uid != int(expected_uid):
    raise SystemExit(1)
root = pathlib.Path(root_path)
first = root / "test-results/case-000.json"
last = root / f"test-results/case-{int(results) - 1:03d}.json"
value = {
    "pid": int(pid),
    "start_time": stat[21],
    "agent_uid": int(expected_uid),
    "root_device": root.stat().st_dev,
    "first_inode": first.stat().st_ino,
    "last_inode": last.stat().st_ino,
    "first_sha256": hashlib.sha256(first.read_bytes()).hexdigest(),
    "last_sha256": hashlib.sha256(last.read_bytes()).hexdigest(),
    "ready": json.loads(pathlib.Path(ready_path).read_text()),
    "progress": json.loads(pathlib.Path(progress_path).read_text()),
}
target = pathlib.Path(trust_path)
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(value, sort_keys=True) + "\n")
print(f"A_TRUST_CAPTURED=1 PID={pid} START_TIME={stat[21]} FIRST_INODE={value['first_inode']} LAST_INODE={value['last_inode']} PROGRESS={value['progress']['verification_cycles']}")
PY
