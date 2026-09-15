#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$A_STATUS_FILE" "$LOCK_PATH" "$TRUST_ROOT/trust.json" <<'PY'
import json
import os
import pathlib
import sys
import time

status_path, lock_path, trust_path = sys.argv[1:]

def proc_start_time(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    return int(text.rsplit(") ", 1)[1].split()[19])

def lock_holders(path):
    st = os.stat(path)
    holders = []
    for line in pathlib.Path("/proc/locks").read_text(errors="replace").splitlines():
        parts = line.split()
        if len(parts) < 6:
            continue
        fields = parts[5].split(":")
        if len(fields) != 3:
            continue
        try:
            major = int(fields[0], 16)
            minor = int(fields[1], 16)
            inode = int(fields[2])
        except ValueError:
            continue
        if major == os.major(st.st_dev) and minor == os.minor(st.st_dev) and inode == st.st_ino:
            holders.append({"type": parts[1], "mode": parts[3], "pid": int(parts[4])})
    return holders

def fail(reason, detail=""):
    suffix = f" {detail}" if detail else ""
    print(f"PEER_OK=0 reason={reason}{suffix}")
    raise SystemExit(1)

try:
    trust = json.loads(pathlib.Path(trust_path).read_text(encoding="utf-8"))
except Exception as exc:
    fail("trust_missing", str(exc))

deadline = time.monotonic() + 4.0
last_status = None
while time.monotonic() < deadline:
    if pathlib.Path(status_path).is_file():
        try:
            status = json.loads(pathlib.Path(status_path).read_text(encoding="utf-8"))
            last_status = status
            pid = int(status.get("pid", -1))
            same_identity = (
                pid == int(trust["pid"])
                and pathlib.Path(f"/proc/{pid}").exists()
                and proc_start_time(pid) == int(trust["start_time"])
            )
            st = os.stat(lock_path)
            same_inode = (
                os.major(st.st_dev) == int(trust["lock_device_major"])
                and os.minor(st.st_dev) == int(trust["lock_device_minor"])
                and st.st_ino == int(trust["lock_inode"])
            )
            holders = lock_holders(lock_path)
            lock_ok = any(item["pid"] == pid and item["mode"] == "WRITE" for item in holders)
            heartbeat_ok = int(status.get("heartbeat_seq", 0)) > int(trust.get("heartbeat_seq", -1))
            phase_ok = status.get("phase") not in {"stopping", "error"}
            generation_ok = int(status.get("db_generation", -1)) >= int(trust.get("db_generation", -1))
            if same_identity and same_inode and lock_ok and heartbeat_ok and phase_ok and generation_ok:
                print(
                    "PEER_OK=1 "
                    f"pid={pid} start_time={trust['start_time']} "
                    f"heartbeat_seq={status.get('heartbeat_seq')} "
                    f"lock_inode={st.st_ino} phase={status.get('phase')} "
                    f"db_generation={status.get('db_generation')}"
                )
                raise SystemExit(0)
        except Exception:
            pass
    time.sleep(0.10)

if last_status is None:
    fail("status_missing")
pid = last_status.get("pid", "unknown")
fail(
    "original_singleton_unhealthy",
    f"pid={pid} heartbeat_seq={last_status.get('heartbeat_seq')} phase={last_status.get('phase')}"
)
PY
