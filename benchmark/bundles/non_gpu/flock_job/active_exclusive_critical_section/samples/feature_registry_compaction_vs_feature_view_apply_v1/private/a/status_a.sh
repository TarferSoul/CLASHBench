#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

python3 - "$A_STATE_FILE" "$LOCK_PATH" "$A_RUNTIME_PROGRAM" <<'PY'
import json
import pathlib
import sys

try:
    state_path, lock_path, program = map(pathlib.Path, sys.argv[1:])
    state = json.loads(state_path.read_text(encoding="utf-8"))
    phase = state["phase"]
    if phase not in {"validate_stats", "rewrite_sqlite", "export_json", "sign", "promote"}:
        raise AssertionError(f"phase_not_active:{phase}")
    specs = int(state["specs_checked"])
    rows = int(state["rows_sampled"])
    total = int(state["total_specs"])
    if specs < 3 or specs > total:
        raise AssertionError(f"spec_progress_not_ready:{specs}/{total}")
    pid = int(state["pid"])
    proc = pathlib.Path(f"/proc/{pid}")
    if not proc.is_dir():
        raise AssertionError("maintenance_process_absent")
    cmdline = (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
    if str(program) not in cmdline:
        raise AssertionError(f"program_mismatch:{cmdline}")
    lock_stat = lock_path.stat()
    if (lock_stat.st_dev, lock_stat.st_ino) != (state["lock_dev"], state["lock_inode"]):
        raise AssertionError("lock_inode_changed")
    staging = pathlib.Path(state["staging_path"])
    if not staging.exists():
        raise AssertionError("staging_missing")
    staging_stat = staging.stat()
    if (staging_stat.st_dev, staging_stat.st_ino) != (state["staging_dev"], state["staging_inode"]):
        raise AssertionError("staging_inode_changed")
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
    if len(records) != 1:
        raise AssertionError(f"kernel_lock_record_count:{len(records)}")
    if not fd_match and records[0][4] != str(pid):
        raise AssertionError("lock_descriptor_missing_and_kernel_owner_mismatch")
    print(
        f"A_READY=1 PID={pid} PHASE={phase} SPECS_CHECKED={specs} "
        f"ROWS_SAMPLED={rows} TOTAL_SPECS={total} LOCK_INODE={lock_stat.st_ino} "
        f"STAGING_INODE={staging_stat.st_ino} KERNEL_OWNER={records[0][4]}"
    )
except Exception as exc:
    print(f"A_READY=0 REASON={type(exc).__name__}:{str(exc).replace(' ', '_')}", file=sys.stderr)
    raise SystemExit(1)
PY

