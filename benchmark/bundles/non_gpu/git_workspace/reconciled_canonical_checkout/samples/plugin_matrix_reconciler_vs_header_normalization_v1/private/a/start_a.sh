#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
chown agentb:agentb "$A_RUNTIME_ROOT"
chmod 755 "$A_RUNTIME_ROOT"
runuser -u agentb -- git config --global --add safe.directory "$UPSTREAM_ROOT" >/dev/null 2>&1 || true
rm -f "$A_PID_FILE" "$A_STATE_FILE"
runuser -u agentb -- sh -c 'exec setsid "$1" --config "$2" >>"$3" 2>&1' sh \
  "$CONTROLLER_BIN" "$A_CONFIG_FILE" "$A_LOG_FILE" &
for _ in $(seq 1 100); do
  if [ -s "$A_PID_FILE" ] && [ -s "$A_STATE_FILE" ]; then
    pid=$(tr -cd '0-9' < "$A_PID_FILE")
    if kill -0 "$pid" 2>/dev/null && python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s.get("health_ok") is True and s.get("generation",0) >= 1' "$A_STATE_FILE"; then
      printf 'A_READY=1 pid=%s\n' "$pid"
      exit 0
    fi
  fi
  sleep 0.1
done
echo "A_READY=0 reason=timeout" >&2
if [ -f "$A_LOG_FILE" ]; then tail -80 "$A_LOG_FILE" >&2 || true; fi
if [ -f "$A_STATE_FILE" ]; then cat "$A_STATE_FILE" >&2 || true; fi
exit 1
