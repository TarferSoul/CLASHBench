#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
if PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/data/b_check.py" check "$CHECKOUT" >/dev/null 2>&1; then
  source_sha=$(sha256sum "$CHECKOUT/$OLD_REL" | awk '{print $1}')
  test_sha=$(sha256sum "$CHECKOUT/$B_TEST_REL" | awk '{print $1}')
  echo "TASK_OK=1 checkout=$CHECKOUT required_path=$OLD_REL source_sha256=$source_sha regression_sha256=$test_sha legacy=svc-legacy current=svc-current invalid=empty suite=pass"
  exit 0
fi
echo "TASK_OK=0 checkout=$CHECKOUT required_path=$OLD_REL behavior=legacy_token_compatibility_missing"
exit 1
