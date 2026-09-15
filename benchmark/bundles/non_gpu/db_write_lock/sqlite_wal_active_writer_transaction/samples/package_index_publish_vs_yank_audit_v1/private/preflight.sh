#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
command -v python3 >/dev/null
python3 - <<'PY'
import hashlib, sqlite3
assert sqlite3.sqlite_version_info >= (3, 8, 0)
assert hashlib.sha256(b"catalog").hexdigest()
PY
test -r "$CASE_PRIVATE_ROOT/data/prepare_db.py"
test -r "$CASE_PRIVATE_ROOT/data/index_builder.py"
test -r "$CASE_PRIVATE_ROOT/data/b_transaction.py"
test -f "$DB_PATH"
test "$(stat -c %U "$DB_PATH")" = agentb
python3 - "$DB_PATH" <<'PY'
import sqlite3, sys
with sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=.2) as conn:
    assert conn.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    assert conn.execute("SELECT count(*) FROM staged_packages").fetchone()[0] == 72
    assert conn.execute("SELECT active_generation FROM registry_state WHERE singleton=1").fetchone()[0] == "gen-stable"
    assert conn.execute("SELECT yanked FROM releases WHERE project='tensorzip' AND version='2.4.1'").fetchone()[0] == 0
    assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
print("PREFLIGHT_OK=1 journal_mode=wal staged_packages=72 active_generation=gen-stable")
PY
