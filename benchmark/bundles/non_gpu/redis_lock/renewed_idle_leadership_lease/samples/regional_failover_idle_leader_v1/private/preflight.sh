#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"
: "${CASE_PUBLIC_ROOT:?}"

for tool in bash python3 redis-server redis-cli runuser setpriv; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "SETUP_FAIL=MISSING_TOOL tool=$tool" >&2
    exit 3
  }
done

test -f "$PRIVATE_CASE/data/initial_route_state.json" || {
  echo "SETUP_FAIL=MISSING_ROUTE_FIXTURE" >&2
  exit 3
}
test -f "$CASE_PUBLIC_ROOT/workload/routectl.py" || {
  echo "SETUP_FAIL=MISSING_ROUTECTL" >&2
  exit 3
}
test -f "$CASE_PUBLIC_ROOT/workload/run_route_reconcile.sh" || {
  echo "SETUP_FAIL=MISSING_ROUTE_RUNNER" >&2
  exit 3
}
test -f "$CASE_PUBLIC_ROOT/workload/configs/us-east-1-api-router-standby-drain.json" || {
  echo "SETUP_FAIL=MISSING_ROUTE_CONFIG" >&2
  exit 3
}

prompt_count=$(find "$CASE_PUBLIC_ROOT/prompts" -maxdepth 1 -type f | wc -l)
if [ "$prompt_count" -ne 7 ]; then
  echo "SETUP_FAIL=PROMPT_COUNT count=$prompt_count" >&2
  exit 3
fi

python3 -m py_compile \
  "$CASE_PUBLIC_ROOT/workload/routectl.py" \
  "$PRIVATE_CASE/a/failover_controller.py" \
  "$PRIVATE_CASE/a/seed_route_state.py" \
  "$PRIVATE_CASE/a/status_a.py" \
  "$PRIVATE_CASE/eval/capture_a_trust.py" \
  "$PRIVATE_CASE/eval/peer_check_a.py" \
  "$PRIVATE_CASE/eval/task_check_b.py" \
  "$PRIVATE_CASE/oracle/lease_observation_check.py"

echo "PREFLIGHT_OK=1"

