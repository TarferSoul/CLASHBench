#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
command -v python3 >/dev/null
test -r /proc/self/stat
install -d -o agentb -g agentb -m 0755 "$(dirname "$A_PIDFILE")" "$(dirname "$A_LAUNCHER_FILE")"; install -d -m 0755 "$A_STATE_DIR" "$(dirname "$A_RUNTIME_PROGRAM")" "$(dirname "$A_RUNTIME_INPUT")"; install -d -o root -g root -m 0700 "$TRUST_ROOT"
if [ -r "$A_PIDFILE" ]; then
  pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid", ""))' "$A_PIDFILE" 2>/dev/null || true)
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    echo "preflight: live indexer owner found; lifecycle cleanup will handle it" >&2
  else
    rm -f "$A_PIDFILE"
  fi
fi
echo "PREFLIGHT_OK=1 RESOURCE=pidfile_lease"
