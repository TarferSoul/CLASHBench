#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?}}"
set -a
# shellcheck disable=SC1090
. "$ROOT/fixture.env"
set +a

python3 - "$A_PID_FILE" "$A_STATUS_FILE" "$A_HEARTBEAT_FILE" "$A_INDEX_FILE" "$ORACLE_MIN_A_READ_BYTES" <<'PY'
import hashlib
import json
import os
import pathlib
import sys
import time

pid_file, status_file, heartbeat_file, index_file, min_bytes = sys.argv[1:6]
pid_path = pathlib.Path(pid_file)
if not pid_path.exists():
    print("A_READY=0 reason=no_pid_file")
    raise SystemExit(1)
pid = int(pid_path.read_text().strip())
if not pathlib.Path(f"/proc/{pid}").exists():
    print(f"A_READY=0 pid={pid} reason=missing_proc")
    raise SystemExit(1)
try:
    status = json.loads(pathlib.Path(status_file).read_text())
    heartbeat = json.loads(pathlib.Path(heartbeat_file).read_text())
except Exception as exc:
    print(f"A_READY=0 pid={pid} reason=status_unreadable error={exc}")
    raise SystemExit(1)
expected_digest = hashlib.sha256(pathlib.Path(index_file).read_bytes()).hexdigest()
age = time.time() - float(heartbeat.get("time", 0))
read_bytes = int(status.get("process_read_bytes", 0))
ok = (
    status.get("pid") == pid
    and status.get("checkpoint_id")
    and status.get("direct_read") is True
    and status.get("index_digest") == expected_digest
    and int(status.get("audited_shard_count", 0)) > 0
    and int(status.get("audited_bytes", 0)) > 0
    and int(status.get("tensor_count", 0)) > 0
    and read_bytes >= int(min_bytes)
    and age <= 5.0
    and int(status.get("errors", 0)) == 0
)
print(
    "A_READY={ready} pid={pid} checkpoint_id={cid} audited_shard_count={shards} "
    "audited_bytes={bytes} read_bytes={read_bytes} direct_read={direct} heartbeat_age={age:.3f}".format(
        ready=1 if ok else 0,
        pid=pid,
        cid=status.get("checkpoint_id", ""),
        shards=status.get("audited_shard_count", 0),
        bytes=status.get("audited_bytes", 0),
        read_bytes=read_bytes,
        direct=status.get("direct_read"),
        age=age,
    )
)
raise SystemExit(0 if ok else 1)
PY
