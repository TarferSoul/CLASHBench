#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_STATUS_FILE" "$DB_PATH" "$A_BATCH_ID" "$A_GENERATION" <<'PY'
import json, os, sqlite3, sys, time
status_path, db, batch_id, generation = sys.argv[1:]
s = json.load(open(status_path))
assert s["phase"] == "active", s
assert s["batch_id"] == batch_id and s["candidate_generation"] == generation
assert s["journal_mode"] == "wal" and s["progress_seq"] >= 5
assert time.time() - s["updated_at"] < 3
pid = int(s["pid"])
assert os.path.isdir(f"/proc/{pid}") and os.stat(f"/proc/{pid}").st_uid > 0
with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=.2) as reader:
    assert reader.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    assert reader.execute("SELECT active_generation FROM registry_state WHERE singleton=1").fetchone()[0] == "gen-stable"
    assert reader.execute("SELECT count(*) FROM staged_packages").fetchone()[0] == 72
busy = False
writer = sqlite3.connect(db, timeout=.1, isolation_level=None)
writer.execute("PRAGMA busy_timeout=100")
try:
    writer.execute("BEGIN IMMEDIATE")
except sqlite3.OperationalError as exc:
    busy = "locked" in str(exc).lower() or "busy" in str(exc).lower()
finally:
    try: writer.rollback()
    except Exception: pass
    writer.close()
assert busy
print(f"A_HEALTHY=1 pid={pid} batch_id={batch_id} generation={generation} progress_seq={s['progress_seq']} resolver_read_ok=1 writer_busy=1")
PY
