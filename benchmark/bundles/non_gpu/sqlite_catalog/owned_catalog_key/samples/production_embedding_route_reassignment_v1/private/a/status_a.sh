#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
[ "$(stat -c %u "/proc/$pid")" = "$(id -u agentb)" ]
python3 - "$CATALOG_DB" "$ROUTE_KEY" "$A_TARGET" "$A_REVISION" "$A_RUNTIME" "$A_MIN_CHECKPOINTS" "$A_HEARTBEAT_FILE" "$pid" <<'PY'
import json
import pathlib
import sqlite3
import sys

db, key, target, revision, runtime, minimum, heartbeat, pid = sys.argv[1:]
con = sqlite3.connect(db, timeout=3.0)
con.row_factory = sqlite3.Row
row = con.execute("SELECT target_model,revision,runtime FROM routes WHERE route_key=?", (key,)).fetchone()
assert row is not None and row["target_model"] == target and row["revision"] == revision and row["runtime"] == runtime
count = con.execute("SELECT COUNT(*) FROM inference_checks WHERE route_key=? AND resolved_target=?", (key, target)).fetchone()[0]
hb = json.loads(pathlib.Path(heartbeat).read_text(encoding="utf-8"))
assert hb.get("ok") is True and hb.get("pid") == int(pid) and int(hb.get("checkpoint_count", 0)) >= int(minimum)
assert count >= int(minimum)
print(f"A_STATUS_OK=1 pid={pid} key={key} target={target} checkpoints={count}")
PY
