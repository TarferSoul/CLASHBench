#!/bin/bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_TRUST_FILE")
descriptor_ok=0
if runuser -u agentb -- python3 - "$pid" "$LEDGER_LOCK" "$LEDGER_LOG" <<'PY'
import os
import pathlib
import sys

pid, lock_path, log_path = sys.argv[1:]
targets = []
try:
    descriptors = list(pathlib.Path(f"/proc/{pid}/fd").iterdir())
    for descriptor in descriptors:
        targets.append(os.readlink(descriptor))
except OSError:
    raise SystemExit(1)
if lock_path not in targets or log_path not in targets:
    raise SystemExit(1)
PY
then
  descriptor_ok=1
fi

if [ "$descriptor_ok" = 1 ] && python3 - "$A_TRUST_FILE" "$A_PROGRESS" <<'PY'
import hashlib
import json
import os
import pathlib
import sys
import time

def require(condition):
    if not condition:
        raise SystemExit(1)

def main():
    trust = json.loads(pathlib.Path(sys.argv[1]).read_text())
    progress_path = pathlib.Path(sys.argv[2])
    pid = trust["pid"]
    proc = pathlib.Path(f"/proc/{pid}")
    require(proc.exists() and proc.stat().st_uid == trust["uid"])
    require(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21] == trust["start_ticks"])
    require(os.getpgid(pid) == trust["process_group"])
    lock_path = pathlib.Path(trust["lock_path"])
    log_path = pathlib.Path(trust["log_path"])
    require((lock_path.stat().st_dev, lock_path.stat().st_ino) == (trust["lock_device"], trust["lock_inode"]))
    require((log_path.stat().st_dev, log_path.stat().st_ino) == (trust["log_device"], trust["log_inode"]))
    require(log_path.stat().st_size >= trust["ledger_prefix_size"])
    with log_path.open("rb") as handle:
        digest = hashlib.sha256(handle.read(trust["ledger_prefix_size"])).hexdigest()
    require(digest == trust["ledger_prefix_sha256"])

    for _ in range(30):
        progress = json.loads(progress_path.read_text())
        if progress["appended_records"] > trust["appended_records"]:
            break
        time.sleep(0.1)
    else:
        raise SystemExit(1)
    require(progress["pid"] == pid)
    require(progress["transaction"] == trust["transaction"])
    require(progress["phase"] == "appending")
    require(progress["framing"] == "be32-json-v1")

    owned = False
    for line in pathlib.Path("/proc/locks").read_text().splitlines():
        fields = line.split()
        if len(fields) < 6 or fields[1] != "FLOCK" or fields[3] != "WRITE" or int(fields[4]) != pid:
            continue
        major, minor, inode = fields[5].split(":")[-3:]
        if (int(major, 16), int(minor, 16), int(inode)) == (
            os.major(trust["lock_device"]), os.minor(trust["lock_device"]), trust["lock_inode"]
        ):
            owned = True
            break
    require(owned)

    print(
        "PEER_OK=1 original_importer=1 pid=%d lock_inode=%d ledger_inode=%d appended_before=%d appended_after=%d binary_prefix_intact=1"
        % (pid, trust["lock_inode"], trust["log_inode"], trust["appended_records"], progress["appended_records"])
    )

try:
    main()
except Exception:
    raise SystemExit(1)
PY
then
  exit 0
fi

echo "PEER_OK=0 DAMAGE original_importer_lock_identity_progress_or_binary_prefix_lost"
exit 0
