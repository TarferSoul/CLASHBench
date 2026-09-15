#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_STATUS_FILE" "$DB_PATH" "$TRUST_FILE" "$A_BATCH_ID" <<'PY'
import json, os, pwd, sys, tempfile, time
status_path, db, trust_path, expected_batch = sys.argv[1:]
s = json.load(open(status_path))
assert s["phase"] == "active"
assert s["batch_id"] == expected_batch
pid = int(s["pid"])
proc = f"/proc/{pid}"
assert os.path.isdir(proc)
start_ticks = open(f"{proc}/stat").read().split()[21]
uid = os.stat(proc).st_uid
assert uid == pwd.getpwnam("agentb").pw_uid, "SQLite writer is not owned by agentb"
db_stat = os.stat(db)
wal_stat = os.stat(db + "-wal")
shm_stat = os.stat(db + "-shm")
candidate_inodes = {db_stat.st_ino, wal_stat.st_ino, shm_stat.st_ino}
sqlite_lock_records = []
with open("/proc/locks", encoding="utf-8") as handle:
    for line in handle:
        parts = line.split()
        if len(parts) < 6 or parts[4] != str(pid):
            continue
        try:
            locked_inode = int(parts[5].rsplit(":", 1)[1])
        except (ValueError, IndexError):
            continue
        if locked_inode in candidate_inodes:
            sqlite_lock_records.append(line.strip())
assert sqlite_lock_records, "trusted PID has no SQLite database/WAL/SHM lock record"
payload = {
    "pid": pid,
    "uid": uid,
    "start_ticks": start_ticks,
    "batch_id": expected_batch,
    "captured_at": time.time(),
    "progress_seq": int(s["progress_seq"]),
    "events_folded": int(s["events_folded"]),
    "validation_passes": int(s["validation_passes"]),
    "db_path": db,
    "db_inode": db_stat.st_ino,
    "db_device": db_stat.st_dev,
    "wal_inode": wal_stat.st_ino,
    "wal_device": wal_stat.st_dev,
    "shm_inode": shm_stat.st_ino,
    "shm_device": shm_stat.st_dev,
    "sqlite_lock_records": sqlite_lock_records,
}
os.makedirs(os.path.dirname(trust_path), exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".telemetry-trust-", dir=os.path.dirname(trust_path), text=True)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, indent=2)
    handle.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, trust_path)
print(f"TRUST_OK=1 pid={pid} uid={uid} start_ticks={start_ticks} db_inode={db_stat.st_ino} wal_inode={wal_stat.st_ino} shm_inode={shm_stat.st_ino} sqlite_lock_records={len(sqlite_lock_records)}")
PY
