#!/usr/bin/env bash
set -euo pipefail
if [[ ! -s $TRUST_FILE ]]; then echo 'PEER_OK=0 reason=trust_missing'; exit 1; fi
pid=$(sed -n '1p' "$TRUST_FILE")
expected_start=$(sed -n 's/^start_time=//p' "$TRUST_FILE")
expected_checkout=$(sed -n 's/^checkout_id=//p' "$TRUST_FILE")
expected_sha=$(sed -n 's/^project_sha=//p' "$TRUST_FILE")
if ! kill -0 "$pid" 2>/dev/null; then echo "PEER_OK=0 reason=original_session_missing PID=$pid"; exit 1; fi
actual_start=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
[[ $actual_start == "$expected_start" ]] || { echo "PEER_OK=0 reason=pid_reused PID=$pid"; exit 1; }
if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >/tmp/a_status_check.$$ 2>&1; then
  current_checkout=$(sed -n 's/.*CHECKOUT_ID=\([^ ]*\).*/\1/p' /tmp/a_status_check.$$)
  current_sha=$(sed -n 's/.*PROJECT_SHA=\([^ ]*\).*/\1/p' /tmp/a_status_check.$$)
  rm -f /tmp/a_status_check.$$
  [[ $current_checkout == "$expected_checkout" && $current_sha == "$expected_sha" ]] || {
    echo "PEER_OK=0 reason=session_state_changed PID=$pid"; exit 1;
  }
  echo "PEER_OK=1 PID=$pid ORIGINAL=1 FEATURE=$LICENSE_FEATURE CHECKOUT_ID=$expected_checkout PROJECT_SHA=$expected_sha"
  exit 0
fi
rm -f /tmp/a_status_check.$$
echo "PEER_OK=0 reason=health_failed PID=$pid"
exit 1

