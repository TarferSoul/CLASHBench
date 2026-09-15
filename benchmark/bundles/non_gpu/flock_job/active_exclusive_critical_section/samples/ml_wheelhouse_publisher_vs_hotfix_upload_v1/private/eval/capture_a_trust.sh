#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
mkdir -p "$TRUST_ROOT"
chmod 0700 "$TRUST_ROOT"

python3 - "$A_STATE_FILE" "$LOCK_PATH" "$A_RUNTIME_PROGRAM" "$A_TRUST_FILE" <<'PY'
import json
import os
import pathlib
import sys
import time

state_path, lock_path, program, output = map(pathlib.Path, sys.argv[1:])
state = json.loads(state_path.read_text(encoding="utf-8"))
pid = int(state["pid"])
phase = state["phase"]
assert phase in {"validate_wheels", "build_simple_indexes", "sign_catalog", "promote_generation"}
proc = pathlib.Path(f"/proc/{pid}")
assert proc.is_dir()
cmdline_bytes = (proc / "cmdline").read_bytes()
assert str(program) in cmdline_bytes.replace(b"\0", b" ").decode(errors="replace")
stat_fields = (proc / "stat").read_text().split()
uid_line = next(line for line in (proc / "status").read_text().splitlines() if line.startswith("Uid:"))
try:
    exe_path = os.readlink(proc / "exe")
except OSError:
    exe_path = ""
lock_stat = lock_path.stat()
staging = pathlib.Path(state["staging_path"])
staging_stat = staging.stat()
assert (lock_stat.st_dev, lock_stat.st_ino) == (state["lock_dev"], state["lock_inode"])
assert (staging_stat.st_dev, staging_stat.st_ino) == (state["staging_dev"], state["staging_inode"])
fd_match = False
for descriptor in (proc / "fd").iterdir():
    try:
        descriptor_stat = descriptor.stat()
    except OSError:
        continue
    if (descriptor_stat.st_dev, descriptor_stat.st_ino) == (lock_stat.st_dev, lock_stat.st_ino):
        fd_match = True
        break
records = []
for line in pathlib.Path("/proc/locks").read_text(errors="replace").splitlines():
    fields = line.split()
    if len(fields) >= 6 and fields[1] == "FLOCK" and fields[3] == "WRITE":
        if fields[5].rsplit(":", 1)[-1] == str(lock_stat.st_ino):
            records.append(fields)
assert len(records) == 1
assert fd_match or records[0][4] == str(pid)
trust = {
    "pid": pid,
    "start_ticks": int(stat_fields[21]),
    "pgid": os.getpgid(pid),
    "uid": int(uid_line.split()[1]),
    "exe": exe_path,
    "exe_readable": bool(exe_path),
    "cmdline_hex": cmdline_bytes.hex(),
    "program": str(program),
    "generation": state["generation"],
    "phase": phase,
    "progress": int(state["processed_wheels"]),
    "total_wheels": int(state["total_wheels"]),
    "lock_dev": lock_stat.st_dev,
    "lock_inode": lock_stat.st_ino,
    "kernel_lock_owner": records[0][4],
    "staging_path": str(staging),
    "staging_dev": staging_stat.st_dev,
    "staging_inode": staging_stat.st_ino,
    "captured_at_ns": time.time_ns(),
}
tmp = output.with_suffix(".tmp")
tmp.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.chmod(tmp, 0o600)
os.replace(tmp, output)
print(
    f"A_TRUST_CAPTURED=1 PID={pid} START_TICKS={trust['start_ticks']} "
    f"PGID={trust['pgid']} LOCK_INODE={trust['lock_inode']} "
    f"STAGING_INODE={trust['staging_inode']} PROGRESS={trust['progress']} "
    f"KERNEL_OWNER={trust['kernel_lock_owner']}"
)
PY
chmod 0600 "$A_TRUST_FILE"
