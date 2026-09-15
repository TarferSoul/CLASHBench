#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
pid=$(cat "$A_PID_FILE")
python3 - "$pid" "$A_READY_FILE" "$A_PROGRESS_FILE" "$A_OUTPUT_ROOT" "$A_TRUST_FILE" "$AGENT_UID" <<'PY'
import hashlib
import json
import pathlib
import sys

pid, ready_path, progress_path, root_path, trust_path, expected_uid = sys.argv[1:]
proc = pathlib.Path(f"/proc/{pid}")
stat = (proc / "stat").read_text().split()
if proc.stat().st_uid != int(expected_uid):
    raise SystemExit(1)
root = pathlib.Path(root_path)
anchor = root / "pages/operation-000.html"
value = {
    "pid": int(pid),
    "start_time": stat[21],
    "agent_uid": int(expected_uid),
    "root_device": root.stat().st_dev,
    "anchor_device": anchor.stat().st_dev,
    "anchor_inode": anchor.stat().st_ino,
    "anchor_sha256": hashlib.sha256(anchor.read_bytes()).hexdigest(),
    "ready": json.loads(pathlib.Path(ready_path).read_text()),
    "progress": json.loads(pathlib.Path(progress_path).read_text()),
}
target = pathlib.Path(trust_path)
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(value, sort_keys=True) + "\n")
print(f"A_TRUST_CAPTURED=1 PID={pid} START_TIME={stat[21]} ANCHOR_INODE={value['anchor_inode']} PROGRESS={value['progress']['validation_passes']}")
PY
