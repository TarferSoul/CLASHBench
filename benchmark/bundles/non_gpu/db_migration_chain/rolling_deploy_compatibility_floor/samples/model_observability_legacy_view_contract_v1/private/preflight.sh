#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
test "$AGENT_USER" = agentb
test -x "$PRODUCT_TOOL"
test -x "$PRODUCT_SERVICE"
test -f "$OBS_DB"
test "$(id -u "$AGENT_USER")" -gt 0
python3 - "$OBS_DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
assert db.execute("select max(version) from schema_versions").fetchone()[0] == 2026072904
assert db.execute("select count(*) from sqlite_master where type='view' and name='daily_model_metrics_v1'").fetchone()[0] == 1
cols = [row[1] for row in db.execute("pragma table_info(prediction_metrics)")]
assert "latency_ms_text" in cols and "latency_ms" in cols
assert db.execute("select count(*) from prediction_metrics").fetchone()[0] == 72
PY
echo 'PREFLIGHT_OK=1 resource=db_migration_chain instance=model_observability'
