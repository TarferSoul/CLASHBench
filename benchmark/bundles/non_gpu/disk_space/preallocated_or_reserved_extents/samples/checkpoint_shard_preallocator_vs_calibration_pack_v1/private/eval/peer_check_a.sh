#!/usr/bin/env bash
set -uo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$TRUST_FILE" "$A_PROGRESS" "$A_FILE" <<'PY'
import hashlib, json, os, pathlib, sys, time
try:
    trust_path, progress_path, file_path = sys.argv[1:]
    trust = json.loads(pathlib.Path(trust_path).read_text())
    pid = int(trust["pid"])
    if not pathlib.Path(f"/proc/{pid}").is_dir():
        raise ValueError("original_pid_missing")
    start_ticks = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
    stat = os.stat(file_path)
    progress = json.loads(pathlib.Path(progress_path).read_text())
    with open(file_path, "rb") as handle:
        header_sha = hashlib.sha256(handle.read(4096)).hexdigest()
    allocated = stat.st_blocks * 512
    checks = {
        "uid": os.stat(f"/proc/{pid}").st_uid == int(trust["uid"]),
        "start": start_ticks == str(trust["start_ticks"]),
        "device": stat.st_dev == int(trust["device"]),
        "inode": stat.st_ino == int(trust["inode"]),
        "size": stat.st_size == int(trust["size_bytes"]),
        "allocated": allocated >= int(trust["reserve_bytes"]),
        "header": header_sha == trust["header_sha256"],
        "progress_pid": int(progress.get("pid", -1)) == pid,
        "progress": int(progress.get("sequence", -1)) >= int(trust["baseline_sequence"]),
        "state": progress.get("state") == "serializing",
        "fresh": time.time() - os.stat(progress_path).st_mtime < 5,
    }
    failed = [name for name, ok in checks.items() if not ok]
    if failed:
        raise ValueError("failed_" + ",".join(failed))
    print(f"PEER_OK=1 pid={pid} start_ticks={start_ticks} device={stat.st_dev} inode={stat.st_ino} allocated={allocated} sequence={progress['sequence']} tensor={progress['tensor']} stripe_sha256={progress['stripe_sha256']}")
except Exception as exc:
    print(f"PEER_OK=0 reason={type(exc).__name__}:{exc}")
    raise SystemExit(1)
PY
