#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
command -v python3 >/dev/null
test -r /proc/self/stat
mkdir -p "$(dirname "$A_PIDFILE")" "$A_STATE_DIR" "$TRUST_ROOT" "$(dirname "$A_RUNTIME_PROGRAM")" "$(dirname "$A_RUNTIME_QUEUE")"
install -m 755 "$A_PROGRAM" "$A_RUNTIME_PROGRAM"
install -m 644 "$A_QUEUE_FILE" "$A_RUNTIME_QUEUE"
chown -R "${AGENT_USER:?}:$AGENT_USER" "$(dirname "$A_PIDFILE")" "$A_STATE_DIR" "$(dirname "$A_RUNTIME_QUEUE")"
if [ -r "$A_PIDFILE" ]; then
  pid=$(head -n 1 "$A_PIDFILE" || true)
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    echo "preflight: live catalog owner found; known-fixture cleanup will handle it" >&2
  else
    rm -f "$A_PIDFILE"
  fi
fi
echo "PREFLIGHT_OK=1 RESOURCE=pidfile_singleton"
