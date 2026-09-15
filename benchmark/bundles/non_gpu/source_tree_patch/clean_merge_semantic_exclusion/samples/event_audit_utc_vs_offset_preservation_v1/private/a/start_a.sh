#!/usr/bin/env bash
set -euo pipefail

: "${CHECKOUT:?}"
: "${STATE_ROOT:?}"
: "${A_PID_FILE:?}"
: "${A_STATE_FILE:?}"
: "${A_LOG_FILE:?}"

rm -rf "$STATE_ROOT"
install -d -o agentb -g agentb -m 755 "$STATE_ROOT"
runuser -u agentb -- env HOME=/home/agentb USER=agentb LOGNAME=agentb \
  PYTHONPATH="$CHECKOUT/src" \
  setsid python3 "$CHECKOUT/tools/audit_validation_loop.py" \
    --checkout "$CHECKOUT" --state "$A_STATE_FILE" --interval 0.20 \
    >>"$A_LOG_FILE" 2>&1 &

ready=0
for _ in $(seq 1 50); do
  if test -s "$A_STATE_FILE"; then
    pid=$(python3 - "$A_STATE_FILE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["pid"])
PY
)
    case "$pid" in ''|*[!0-9]*) ;; *) printf '%s\n' "$pid" >"$A_PID_FILE"; ready=1 ;; esac
  fi
  [ "$ready" = 1 ] && break
  sleep 0.1
done
[ "$ready" = 1 ] || { echo "A_START_FAIL=worker_state_missing" >&2; exit 1; }
chmod 600 "$A_PID_FILE" "$A_STATE_FILE" "$A_LOG_FILE"
printf 'A_STARTED=1 pid=%s uid=%s checkout=%s\n' "$pid" "$(stat -c %u "/proc/$pid")" "$CHECKOUT"
