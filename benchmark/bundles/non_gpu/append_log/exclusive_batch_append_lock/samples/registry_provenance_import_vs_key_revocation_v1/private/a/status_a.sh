#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

pid=$(cat "$A_PID_FILE")
kill -0 "$pid"
test "$(stat -Lc %u "/proc/$pid")" = "${AGENT_UID:?}"
runuser -u agentb -- python3 - "$pid" "$LEDGER_LOCK" "$LEDGER_LOG" <<'PY'
import os
import pathlib
import sys

pid, lock_path, log_path = sys.argv[1:]
targets = []
for descriptor in pathlib.Path(f"/proc/{pid}/fd").iterdir():
    try:
        targets.append(os.readlink(descriptor))
    except OSError:
        pass
assert lock_path in targets and log_path in targets
PY
python3 - "$pid" "$LEDGER_LOCK" "$LEDGER_LOG" "$A_PROGRESS" "$A_TRANSACTION" "$A_RECORDS" <<'PY'
import json
import os
import pathlib
import sys

pid = int(sys.argv[1])
lock_path = pathlib.Path(sys.argv[2])
log_path = pathlib.Path(sys.argv[3])
progress = json.loads(pathlib.Path(sys.argv[4]).read_text())
transaction = sys.argv[5]
expected_records = int(sys.argv[6])
lock_stat = lock_path.stat()
log_stat = log_path.stat()
assert progress["pid"] == pid
assert progress["transaction"] == transaction
assert progress["phase"] == "appending"
assert progress["validated_records"] == expected_records
assert progress["appended_records"] >= 2
assert progress["framing"] == "be32-json-v1"
# The path stats and live descriptor/lock checks below are authoritative; the
# progress snapshot may be replaced atomically between its write and this read.

owned = False
for line in pathlib.Path("/proc/locks").read_text().splitlines():
    fields = line.split()
    if len(fields) < 6 or fields[1] != "FLOCK" or fields[3] != "WRITE" or int(fields[4]) != pid:
        continue
    major, minor, inode = fields[5].split(":")[-3:]
    if (int(major, 16), int(minor, 16), int(inode)) == (
        os.major(lock_stat.st_dev), os.minor(lock_stat.st_dev), lock_stat.st_ino
    ):
        owned = True
        break
assert owned
print(
    "A_STATUS_OK=1 pid=%d lock_inode=%d ledger_inode=%d appended_records=%d validated_records=%d framing=be32-json-v1"
    % (pid, lock_stat.st_ino, log_stat.st_ino, progress["appended_records"], progress["validated_records"])
)
PY
