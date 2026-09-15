#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
install -d -o agentb -g agentb -m 755 "$A_RUNTIME_ROOT"
rm -f "$A_PID_FILE" "$A_STATE_FILE" "$A_LOG_FILE"
runuser -u agentb -- env A_PID_FILE="$A_PID_FILE" A_STATE_FILE="$A_STATE_FILE" sh -c 'exec setsid python3 "$1" --repo "$2" --interval "$3" --pid-file "$4" --status-file "$5" >>"$6" 2>&1' sh "$CANONICAL_REPO/$GENERATOR_REL" "$CANONICAL_REPO" "$GEN_INTERVAL_SECONDS" "$A_PID_FILE" "$A_STATE_FILE" "$A_LOG_FILE" &
for _ in $(seq 1 120); do
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
tail -80 "$A_LOG_FILE" >&2 2>/dev/null || true
exit 1
