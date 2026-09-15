#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

install -d -o root -g root -m 700 "$A_TRUST_DIR"

python3 - "$A_TRUST_DIR/trust.json" "$A_STATUS_FILE" "$A_PID_FILE" "$A_DATA_DIR" "$B_SCRATCH" <<'PY'
import json, os, pathlib, sys, time

out, status_path, pid_file, a_path, b_path = sys.argv[1:]

def read_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except Exception:
        return {}

def proc_start(pid):
    try:
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text()
        return stat.rsplit(") ", 1)[1].split()[19]
    except Exception:
        return ""

def path_dev(path):
    try:
        st = pathlib.Path(path).stat()
        return {"st_dev": st.st_dev, "major": os.major(st.st_dev), "minor": os.minor(st.st_dev)}
    except OSError as exc:
        return {"error": str(exc)}

status = read_json(status_path)
pid = int(pathlib.Path(pid_file).read_text().strip())
trust = {
    "captured_at": time.time(),
    "pid": pid,
    "start_time": proc_start(pid),
    "pgid": os.getpgid(pid),
    "status": status,
    "worker_identities": [
        {"pid": int(item.get("pid") or 0), "start_time": str(item.get("start_time", "")), "worker_id": item.get("worker_id")}
        for item in status.get("workers", [])
        if item.get("alive") and item.get("phase") != "complete"
    ],
    "path_devices": {"a_data": path_dev(a_path), "b_scratch": path_dev(b_path)}
}
pathlib.Path(out).write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
PY

chmod 600 "$A_TRUST_DIR/trust.json"
echo "TRUST_OK=1 path=$A_TRUST_DIR/trust.json"
