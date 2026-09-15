#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?}}"
set -a
# shellcheck disable=SC1090
. "$ROOT/fixture.env"
set +a

mkdir -p "$A_TRUST_DIR"
chmod 700 "$A_TRUST_DIR"
python3 - "$A_PID_FILE" "$A_STATUS_FILE" "$A_INDEX_FILE" "$A_VISIBLE_ROOT" "$B_CHECKPOINT_ROOT" "$A_TRUST_DIR/trust.json" <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time

pid_file, status_file, index_file, a_root, b_root, out = sys.argv[1:7]
pid = int(pathlib.Path(pid_file).read_text().strip())
status = json.loads(pathlib.Path(status_file).read_text())
stat_text = pathlib.Path(f"/proc/{pid}/stat").read_text()
start_time = stat_text.rsplit(") ", 1)[1].split()[19]
pgid = os.getpgid(pid)

def identity(path):
    st = pathlib.Path(path).stat()
    try:
        mount = subprocess.run(["findmnt", "-n", "-T", str(path), "-o", "SOURCE,TARGET,FSTYPE,OPTIONS"],
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=3, check=False).stdout.strip()
    except Exception as exc:
        mount = f"findmnt_error:{exc}"
    return {
        "path": str(path),
        "st_dev": st.st_dev,
        "major": os.major(st.st_dev),
        "minor": os.minor(st.st_dev),
        "mount": mount,
    }

payload = {
    "captured_at": time.time(),
    "pid": pid,
    "start_time": start_time,
    "pgid": pgid,
    "checkpoint_id": status.get("checkpoint_id"),
    "index_digest": hashlib.sha256(pathlib.Path(index_file).read_bytes()).hexdigest(),
    "status": status,
    "a_identity": identity(a_root),
    "b_identity": identity(b_root),
    "same_st_dev": identity(a_root)["st_dev"] == identity(b_root)["st_dev"],
}
path = pathlib.Path(out)
path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
print("A_TRUST_CAPTURED=1 pid={pid} start_time={start} pgid={pgid} checkpoint_id={cid} same_st_dev={same}".format(
    pid=pid, start=start_time, pgid=pgid, cid=payload["checkpoint_id"], same=payload["same_st_dev"]))
PY
