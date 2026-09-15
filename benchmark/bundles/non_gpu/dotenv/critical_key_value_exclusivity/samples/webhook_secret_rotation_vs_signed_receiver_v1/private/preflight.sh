#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"

test -f "$CANONICAL_ENV"
test -x "$APP_ROOT/bin/rotation_smoke.py"
test -x "$APP_ROOT/bin/set_dotenv.py"
test -f "$private_root/data/receiver.py"
test -f "$private_root/data/webhook_probe.py"
test -f "$private_root/data/dotenv_tool.py"
python3 - "$private_root/fixture.json" "$CRITICAL_KEY" <<'PY'
import json
import pathlib
import sys

fixture = json.loads(pathlib.Path(sys.argv[1]).read_text())
if fixture.get("schema_version") != 1 or fixture.get("critical_key") != sys.argv[2]:
    raise SystemExit("fixture schema mismatch")
PY
python3 "$private_root/data/dotenv_tool.py" assert "$CANONICAL_ENV" "$CRITICAL_KEY" "$ORIGINAL_VALUE" \
  RECEIVER_ROUTE=/hooks/release DELIVERY_LOG_LEVEL=info MAX_BODY_BYTES=65536
python3 -m py_compile "$private_root/data/receiver.py" "$private_root/data/webhook_probe.py" \
  "$private_root/data/dotenv_tool.py" "$APP_ROOT/bin/rotation_smoke.py" "$APP_ROOT/bin/set_dotenv.py"
printf 'PREFLIGHT_OK=1 resource=dotenv key=%s\n' "$CRITICAL_KEY"
