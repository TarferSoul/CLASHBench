#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >/dev/null
python3 - "$A_PID_FILE" "$A_PROGRESS" "$A_FILE" "$A_HEADER" "$TRUST_FILE" <<'PY'
import hashlib, json, os, pathlib, sys
pid_path, progress_path, file_path, header, trust_path = sys.argv[1:]
pid = int(pathlib.Path(pid_path).read_text().strip())
progress = json.loads(pathlib.Path(progress_path).read_text())
stat = os.stat(file_path)
start_ticks = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
with open(file_path, "rb") as handle:
    header_bytes = handle.read(4096)
payload = {
    "pid": pid,
    "uid": os.stat(f"/proc/{pid}").st_uid,
    "start_ticks": start_ticks,
    "device": stat.st_dev,
    "inode": stat.st_ino,
    "size_bytes": stat.st_size,
    "allocated_bytes": stat.st_blocks * 512,
    "reserve_bytes": int(progress["reserve_bytes"]),
    "header": header,
    "header_sha256": hashlib.sha256(header_bytes).hexdigest(),
    "baseline_sequence": int(progress["sequence"]),
    "baseline_lsn": progress["durable_lsn"],
}
pathlib.Path(trust_path).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
os.chmod(trust_path, 0o600)
print(f"TRUST_CAPTURED=1 pid={pid} uid={payload['uid']} start_ticks={start_ticks} device={stat.st_dev} inode={stat.st_ino} allocated={payload['allocated_bytes']} sequence={payload['baseline_sequence']} lsn={payload['baseline_lsn']}")
PY

