#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"
test -s "$A_PID_FILE"
pid=$(cat "$A_PID_FILE")
kill -0 "$pid" 2>/dev/null
python3 "$private_root/data/dotenv_tool.py" assert "$CANONICAL_ENV" "$CRITICAL_KEY" "$ORIGINAL_VALUE" \
  CHECKPOINT_STREAM=settlements-eu CHECKPOINT_INTERVAL_MS=200 EXPECTED_CLUSTER=primary-ledger >/dev/null
read -r state sequence age < <(python3 - "$A_STATE_FILE" <<'PY'
import json, pathlib, sys, time
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(d.get("status", "missing"), d.get("sequence", 0), time.time() - float(d.get("observed_at", 0)))
PY
)
[ "$state" = healthy ]
[ "$sequence" -gt 0 ]
python3 - "$age" <<'PY'
import sys
raise SystemExit(0 if 0 <= float(sys.argv[1]) < 2.5 else 1)
PY
db_sequence=$(python3 - "$PRIMARY_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print(c.execute("SELECT coalesce(max(sequence), 0) FROM settlement_checkpoint_heartbeats").fetchone()[0])
c.close()
PY
)
[ "$db_sequence" -ge "$sequence" ]
printf 'A_HEALTHY=1 pid=%s cluster=primary-ledger checkpoint_sequence=%s\n' "$pid" "$sequence"
