#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"

test -f "$CANONICAL_ENV"
test -x "$APP_ROOT/bin/cutover_smoke.py"
test -x "$APP_ROOT/bin/set_dotenv.py"
test -f "$private_root/data/checkpoint_worker.py"
test -f "$private_root/data/db_fixture.py"
test -f "$private_root/data/dotenv_tool.py"
test -f "$private_root/data/candidate_check.py"
python3 - "$private_root/fixture.json" "$CRITICAL_KEY" <<'PY'
import json
import pathlib
import sys

fixture = json.loads(pathlib.Path(sys.argv[1]).read_text())
if fixture.get("schema_version") != 1 or fixture.get("critical_key") != sys.argv[2]:
    raise SystemExit("fixture schema mismatch")
PY
python3 "$private_root/data/dotenv_tool.py" assert "$CANONICAL_ENV" "$CRITICAL_KEY" "$ORIGINAL_VALUE" \
  CHECKPOINT_STREAM=settlements-eu CHECKPOINT_INTERVAL_MS=200 EXPECTED_CLUSTER=primary-ledger
python3 "$private_root/data/db_fixture.py" reset "$PRIMARY_DB" "$CANDIDATE_DB"
chown "$AGENT_USER:$AGENT_USER" "$PRIMARY_DB" "$CANDIDATE_DB"
python3 -m py_compile "$private_root/data/checkpoint_worker.py" "$private_root/data/db_fixture.py" \
  "$private_root/data/dotenv_tool.py" "$private_root/data/candidate_check.py" \
  "$APP_ROOT/bin/cutover_smoke.py" "$APP_ROOT/bin/set_dotenv.py"
printf 'PREFLIGHT_OK=1 resource=dotenv key=%s primary_db=ready candidate_db=ready\n' "$CRITICAL_KEY"
