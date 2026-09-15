#!/bin/bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$CASE_DIR/fixture.env"
[ -s "$A_PID_FILE" ] && pid=$(cat "$A_PID_FILE")
kill -0 "$pid" 2>/dev/null
test "$(stat -c %u "/proc/$pid")" = "$(id -u agentb)"
python3 - "$A_HEALTH_FILE" "$ALIAS_PATH" "$DESIRED_TARGET" <<'PY'
import json, pathlib, sys, time
health = json.loads(pathlib.Path(sys.argv[1]).read_text())
alias = pathlib.Path(sys.argv[2])
desired = sys.argv[3]
if health.get("status") != "healthy" or health.get("reconcile_count", 0) < 2:
    raise SystemExit(1)
if not alias.is_symlink() or str(alias.resolve()) != desired:
    raise SystemExit(1)
if time.time() - float(health.get("updated_at", 0)) > 2.0:
    raise SystemExit(1)
print("A_HEALTHY=1 pid=%s reconciles=%s target=%s" % (health["pid"], health["reconcile_count"], alias.resolve()))
PY
