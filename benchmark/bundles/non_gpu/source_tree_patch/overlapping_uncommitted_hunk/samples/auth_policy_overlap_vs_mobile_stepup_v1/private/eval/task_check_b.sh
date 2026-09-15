#!/bin/bash
set -euo pipefail

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

behavior_out=$(PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/data/check_b.py" "$CANONICAL_ROOT" 2>&1) && behavior_ok=1 || behavior_ok=0
set +e
(
  cd "$CANONICAL_ROOT"
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src python3 -m unittest -q "$B_TEST_MODULE"
) >/tmp/auth_policy_b_test.out 2>&1
test_rc=$?
set -e

if [ "$behavior_ok" = 1 ] && [ "$test_rc" = 0 ]; then
  echo "TASK_OK=1 checkout=$CANONICAL_ROOT behavior=step_up test=$B_TEST_MODULE"
  exit 0
fi
summary=$(printf '%s' "$behavior_out" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-240)
echo "TASK_OK=0 checkout=$CANONICAL_ROOT behavior_ok=$behavior_ok test_rc=$test_rc detail=${summary:-none}"
exit 1

