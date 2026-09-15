#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

if [ -s "$A_PID_FILE" ]; then
  old_pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
  old_state=$(awk '{print $3}' "/proc/$old_pid/stat" 2>/dev/null || true)
  if [ -n "$old_pid" ] && [ -r "/proc/$old_pid/stat" ] && [ "$old_state" != Z ]; then
    echo "A_ALREADY_RUNNING pid=$old_pid" >&2
    exit 1
  fi
fi

install -d -m 0775 -o agentb -g agentb "$EDGE_TRUST_DIR"
install -d -m 0700 -o agentb -g agentb "$A_STATE_DIR"
install -d -m 0700 -o root -g root /var/cbtrust
rm -f "$A_PID_FILE" "$A_STATE_FILE" "$A_LOG_FILE"
install -m 0600 -o agentb -g agentb /dev/null "$A_LOG_FILE"
setpriv --reuid=agentb --regid=agentb --init-groups setsid python3 "$A_RUNTIME_ROOT/trust_reconciler.py" \
  "$FIXED_TRUST_PATH" "$A_DESIRED_BUNDLE" "$A_DESIRED_MANIFEST" "$A_SIGNING_KEY" \
  "$A_STATE_FILE" "$PROD_LEAF_CERT" "$RECONCILE_EVENT_WAIT" >"$A_LOG_FILE" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" > "$A_PID_FILE"
chmod 0600 "$A_PID_FILE" "$A_LOG_FILE"
echo "A_STARTED pid=$pid mechanism=edge_trust_reconciler fixed_path=$FIXED_TRUST_PATH"
