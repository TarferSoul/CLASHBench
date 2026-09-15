#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
command -v python3 >/dev/null
python3 - <<'PY'
import sqlite3
assert sqlite3.sqlite_version_info >= (3, 8, 0)
PY
test -r "$CASE_PRIVATE_ROOT/data/prepare_db.py"
test -r "$CASE_PRIVATE_ROOT/data/rollup_worker.py"
test -r "$CASE_PRIVATE_ROOT/data/b_transaction.py"
test -f "$DB_PATH"
test "$(stat -c %U "$DB_PATH")" = agentb
python3 - "$DB_PATH" <<'PY'
import sqlite3, sys
db = sys.argv[1]
with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=.2) as conn:
    mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
    assert mode.lower() == "wal", mode
    assert conn.execute("SELECT count(*) FROM staged_events").fetchone()[0] == 96
    assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
print("PREFLIGHT_OK=1 journal_mode=wal staged_events=96")
PY
