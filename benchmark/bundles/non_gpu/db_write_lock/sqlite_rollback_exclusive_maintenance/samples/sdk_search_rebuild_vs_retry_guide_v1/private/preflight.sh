#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"
for command in /usr/bin/python3 setpriv runuser awk stat; do command -v "$command" >/dev/null; done
for path in "$ROOT/setup.sh" "$ROOT/a/start_a.sh" "$ROOT/a/status_a.sh" "$ROOT/a/stop_a.sh" \
  "$ROOT/eval/capture_a_trust.sh" "$ROOT/eval/peer_check_a.sh" "$ROOT/eval/task_check_b.sh" \
  "$ROOT/oracle/conflict_oracle.sh" "$ROOT/data/seed_search_catalog.py" \
  "$ROOT/data/rebuild_search_index.py" "$ROOT/data/publish_retry_guide.py" "$ROOT/data/probe_database.py"; do
  [ -s "$path" ]
done
read -r mode version documents indexed integrity fts5 < <(/usr/bin/python3 - "$LIVE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
options = {row[0] for row in c.execute("PRAGMA compile_options")}
print(c.execute("PRAGMA journal_mode").fetchone()[0], c.execute("PRAGMA user_version").fetchone()[0],
      c.execute("SELECT COUNT(*) FROM documents").fetchone()[0], c.execute("SELECT COUNT(*) FROM docs_search").fetchone()[0],
      c.execute("PRAGMA integrity_check").fetchone()[0], int(any("ENABLE_FTS5" in value for value in options)))
c.close()
PY
)
[ "$mode" = delete ]
[ "$version" = "$SOURCE_SCHEMA_VERSION" ]
[ "$documents" = "$DOCUMENT_ROWS" ]
[ "$indexed" = "$DOCUMENT_ROWS" ]
[ "$integrity" = ok ]
[ "$fts5" = 1 ]
echo "PREFLIGHT_OK=1 JOURNAL_MODE=$mode USER_VERSION=$version DOCUMENTS=$documents INDEXED=$indexed INTEGRITY=$integrity FTS5=$fts5"
