#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
[ "$(id -u)" -eq 0 ]
id agentb >/dev/null
[ "$(id -u agentb)" -gt 0 ]
test -x "$PROGRAM"
test -x /usr/bin/setpriv
test -r "$A_INPUT_RUNTIME"
test -r "$B_INPUT"
test -d "$(dirname "$PIDFILE")"
test -d "$STATE_DIR"
/usr/bin/setpriv --reuid=agentb --regid=agentb --init-groups -- test -w "$(dirname "$PIDFILE")"
/usr/bin/setpriv --reuid=agentb --regid=agentb --init-groups -- test -w "$STATE_DIR"
python3 - "$PROGRAM" <<'PY'
import ast, pathlib, sys
ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
PY
printf 'PREFLIGHT_OK=1 user=agentb lock_kind=%s pidfile=%s\n' "$LOCK_KIND" "$PIDFILE"
