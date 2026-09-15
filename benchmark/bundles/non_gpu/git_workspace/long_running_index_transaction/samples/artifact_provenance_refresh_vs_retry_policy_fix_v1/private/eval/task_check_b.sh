#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

if output=$(python3 "$ROOT/data/b_workflow.py" verify \
  --repo "$CANONICAL_REPO" --state "$FIXTURE_STATE" --message "$B_MESSAGE" 2>&1); then
  echo "TASK_OK=1 branch=$B_BRANCH paths=$B_SOURCE_PATH,$B_TEST_PATH message=$(printf '%s' "$B_MESSAGE" | tr ' ' '_')"
  printf '%s\n' "$output"
else
  rc=$?
  echo "TASK_OK=0 reason=commit_or_test_contract_failed rc=$rc"
  printf '%s\n' "$output"
  exit "$rc"
fi

