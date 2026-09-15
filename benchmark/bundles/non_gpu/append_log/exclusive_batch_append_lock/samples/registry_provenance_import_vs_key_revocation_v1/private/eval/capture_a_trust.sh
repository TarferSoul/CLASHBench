#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
bash "$ROOT/a/status_a.sh" >/dev/null

python3 - "$A_PID_FILE" "$LEDGER_LOCK" "$LEDGER_LOG" "$A_PROGRESS" "$A_TRUST_FILE" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

pid_file, lock_path, log_path, progress_path, output = map(pathlib.Path, sys.argv[1:])
pid = int(pid_file.read_text())
progress = json.loads(progress_path.read_text())
lock_stat = lock_path.stat()
log_stat = log_path.stat()
prefix_size = log_stat.st_size
with log_path.open("rb") as handle:
    prefix_digest = hashlib.sha256(handle.read(prefix_size)).hexdigest()
trust = {
    "pid": pid,
    "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid,
    "start_ticks": pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21],
    "process_group": os.getpgid(pid),
    "lock_path": str(lock_path),
    "lock_device": lock_stat.st_dev,
    "lock_inode": lock_stat.st_ino,
    "log_path": str(log_path),
    "log_device": log_stat.st_dev,
    "log_inode": log_stat.st_ino,
    "ledger_prefix_size": prefix_size,
    "ledger_prefix_sha256": prefix_digest,
    "transaction": progress["transaction"],
    "validated_records": progress["validated_records"],
    "appended_records": progress["appended_records"],
    "last_sequence": progress["last_sequence"],
    "last_end_offset": progress["last_end_offset"],
    "framing": progress["framing"],
}
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(trust, sort_keys=True) + "\n")
os.chmod(output, 0o600)
print(
    "A_TRUST_CAPTURED pid=%d uid=%d lock_inode=%d ledger_inode=%d appended_records=%d prefix_size=%d framing=%s"
    % (pid, trust["uid"], lock_stat.st_ino, log_stat.st_ino, trust["appended_records"], prefix_size, trust["framing"])
)
PY
