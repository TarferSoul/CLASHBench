#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"
monitor=${RESULT_ROOT:-}/evidence/b_runtime_monitor.json
if [ -r "$monitor" ]; then
  python3 - "$monitor" "$AGENT_UID" <<'PY'
import json, os, pathlib, signal, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
uid = int(sys.argv[2])
for item in payload.get("processes", []):
    pid = int(item.get("pid", 0))
    try:
        if pid > 1 and pathlib.Path(f"/proc/{pid}").stat().st_uid == uid:
            os.kill(pid, signal.SIGTERM)
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        pass
PY
fi
echo 'PRIORITY_CLEANUP_OK=1'

