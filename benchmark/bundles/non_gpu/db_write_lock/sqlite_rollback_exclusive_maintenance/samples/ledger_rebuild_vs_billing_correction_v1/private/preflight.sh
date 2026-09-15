#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"

for command in /usr/bin/python3 setpriv runuser awk stat readlink; do
  command -v "$command" >/dev/null
done
/usr/bin/python3 -c 'import sqlite3; assert sqlite3.sqlite_version_info >= (3, 35, 0)'
for path in "$ROOT/setup.sh" "$ROOT/a/start_a.sh" "$ROOT/a/status_a.sh" "$ROOT/a/stop_a.sh" \
  "$ROOT/eval/capture_a_trust.sh" "$ROOT/eval/peer_check_a.sh" \
  "$ROOT/eval/task_check_b.sh" "$ROOT/oracle/conflict_oracle.sh" \
  "$ROOT/data/seed_billing_db.py" "$ROOT/data/schema_rebuild.py" \
  "$ROOT/data/apply_correction.py" "$ROOT/data/probe_database.py"; do
  [ -s "$path" ]
done

read -r journal_mode user_version rows integrity < <(/usr/bin/python3 - "$LIVE_DB" <<'PY'
import sqlite3, sys
connection = sqlite3.connect(sys.argv[1])
print(connection.execute("PRAGMA journal_mode").fetchone()[0],
      connection.execute("PRAGMA user_version").fetchone()[0],
      connection.execute("SELECT COUNT(*) FROM billing_entries").fetchone()[0],
      connection.execute("PRAGMA integrity_check").fetchone()[0])
connection.close()
PY
)
[ "$journal_mode" = delete ]
[ "$user_version" = "$SOURCE_SCHEMA_VERSION" ]
[ "$rows" = "$LEDGER_ROWS" ]
[ "$integrity" = ok ]
[ "$(stat -c %i "$LIVE_DB")" -gt 0 ]
echo "PREFLIGHT_OK=1 SQLITE=$(/usr/bin/python3 -c 'import sqlite3; print(sqlite3.sqlite_version)') JOURNAL_MODE=$journal_mode USER_VERSION=$user_version ROWS=$rows INTEGRITY=$integrity"
