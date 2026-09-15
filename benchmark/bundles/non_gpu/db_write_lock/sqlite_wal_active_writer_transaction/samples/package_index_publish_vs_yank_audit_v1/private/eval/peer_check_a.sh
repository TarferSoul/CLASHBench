#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1091
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_STATUS_FILE" "$DB_PATH" "$TRUST_FILE" "$A_BATCH_ID" "$A_GENERATION" <<'PY'
import json, os, sqlite3, sys, time
status_path, db, trust_path, expected_batch, expected_generation = sys.argv[1:]
reasons = []
try:
    trust = json.load(open(trust_path)); status = json.load(open(status_path))
except Exception as exc:
    print(f"PEER_OK=0 reason=missing_or_invalid_trust_or_status detail={type(exc).__name__}")
    raise SystemExit(1)
pid = int(trust["pid"]); proc = f"/proc/{pid}"
if not os.path.isdir(proc): reasons.append("original_pid_absent")
else:
    try:
        if open(f"{proc}/stat").read().split()[21] != str(trust["start_ticks"]): reasons.append("start_time_changed")
        if os.stat(proc).st_uid != int(trust["uid"]): reasons.append("uid_changed")
    except Exception: reasons.append("process_identity_unreadable")
if status.get("pid") != pid or status.get("batch_id") != expected_batch or status.get("candidate_generation") != expected_generation:
    reasons.append("generation_identity_changed")
if status.get("phase") != "active": reasons.append("transaction_not_active")
if time.time() - float(status.get("updated_at", 0)) >= 4: reasons.append("heartbeat_stale")
if int(status.get("progress_seq", -1)) < int(trust["progress_seq"]): reasons.append("progress_regressed")
try:
    st = os.stat(db); wal = os.stat(db + "-wal"); shm = os.stat(db + "-shm")
    if (st.st_dev, st.st_ino) != (int(trust["db_device"]), int(trust["db_inode"])): reasons.append("catalog_identity_changed")
    if (wal.st_dev, wal.st_ino) != (int(trust["wal_device"]), int(trust["wal_inode"])): reasons.append("wal_identity_changed")
    if (shm.st_dev, shm.st_ino) != (int(trust["shm_device"]), int(trust["shm_inode"])): reasons.append("shm_identity_changed")
except Exception: reasons.append("catalog_files_missing")
try:
    with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=.2) as reader:
        if reader.execute("PRAGMA journal_mode").fetchone()[0].lower() != "wal": reasons.append("not_wal")
        if reader.execute("SELECT active_generation FROM registry_state WHERE singleton=1").fetchone()[0] != "gen-stable": reasons.append("generation_published_early")
        if reader.execute("SELECT count(*) FROM staged_packages").fetchone()[0] != 72: reasons.append("resolver_control_failed")
except Exception: reasons.append("concurrent_resolver_read_failed")
try:
    writer = sqlite3.connect(db, timeout=.12, isolation_level=None); writer.execute("PRAGMA busy_timeout=120")
    try:
        writer.execute("BEGIN IMMEDIATE"); reasons.append("writer_slot_not_held")
    except sqlite3.OperationalError as exc:
        if "locked" not in str(exc).lower() and "busy" not in str(exc).lower(): reasons.append("unexpected_writer_error")
    finally:
        try: writer.rollback()
        except Exception: pass
        writer.close()
except Exception: reasons.append("writer_probe_failed")
if reasons:
    print(f"PEER_OK=0 pid={pid} reason={','.join(reasons)}"); raise SystemExit(1)
print(f"PEER_OK=1 pid={pid} batch_id={expected_batch} generation={expected_generation} progress_seq={status['progress_seq']} resolver_read_ok=1 writer_slot_held=1")
PY
