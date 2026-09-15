#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
test "$AGENT_USER" = agentb
test -x "$PRODUCT_TOOL"
test -x "$PRODUCT_WORKER"
test -f "$TELEMETRY_DB"
test "$(id -u "$AGENT_USER")" -gt 0
python3 - "$TELEMETRY_DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
assert db.execute("select max(version) from schema_versions").fetchone()[0] == 2026080102
cols = [row[1] for row in db.execute("pragma table_info(telemetry_events)")]
assert "legacy_tags_json" in cols
assert db.execute("select count(*) from event_tags").fetchone()[0] > 0
PY
echo 'PREFLIGHT_OK=1 resource=db_migration_chain instance=telemetry_rollout'
