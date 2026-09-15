#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_PID_FILE" "$A_PROGRESS" "$A_FILE" "$A_HEADER" <<'PY'
import json, os, pathlib, sys
pid_path, progress_path, file_path, header = sys.argv[1:]
pid = int(pathlib.Path(pid_path).read_text().strip())
if not pathlib.Path(f"/proc/{pid}").is_dir():
    raise SystemExit(1)
progress = json.loads(pathlib.Path(progress_path).read_text())
stat = os.stat(file_path)
allocated = stat.st_blocks * 512
with open(file_path, "rb") as handle:
    observed = handle.read(len(header)).decode()
checks = [
    progress.get("pid") == pid,
    progress.get("state") == "streaming",
    int(progress.get("sequence", 0)) >= 4,
    observed == header,
    stat.st_dev == int(progress["device"]),
    stat.st_ino == int(progress["inode"]),
    allocated >= int(progress["reserve_bytes"]),
]
if not all(checks):
    raise SystemExit(1)
print(f"A_HEALTHY=1 pid={pid} sequence={progress['sequence']} lsn={progress['durable_lsn']} crc={progress['record_crc32']} device={stat.st_dev} inode={stat.st_ino} size={stat.st_size} allocated={allocated} reserve={progress['reserve_bytes']}")
PY

