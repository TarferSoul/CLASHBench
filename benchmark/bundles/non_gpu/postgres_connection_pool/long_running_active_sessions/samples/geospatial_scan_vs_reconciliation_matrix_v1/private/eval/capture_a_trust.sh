#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/fixture.env"

install -d -o root -g root -m 700 "$TRUST_ROOT"
tmp="$TRUST_FILE.tmp.$$"
A_STATUS_SNAPSHOT="$tmp" bash "$ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/trust_capture_status.txt" 2>&1
/usr/bin/python3 - "$tmp" "$TRUST_FILE" <<'PY'
import json
import pathlib
import sys
import time

source, target = map(pathlib.Path, sys.argv[1:])
data = json.loads(source.read_text())
data["trust_captured_at_epoch"] = time.time()
data["trust_kind"] = "postgres_connection_pool_long_running_active_sessions"
target.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
target.chmod(0o600)
source.unlink(missing_ok=True)
print(
    "A_TRUST_CAPTURED=1 "
    f"SUPERVISOR_PID={data.get('supervisor_pid')} "
    f"BACKENDS={data.get('backend_count')} "
    f"ACTIVE={data.get('active_backend_count')} "
    f"TOTAL_BYTES={data.get('total_output_bytes')}"
)
PY
