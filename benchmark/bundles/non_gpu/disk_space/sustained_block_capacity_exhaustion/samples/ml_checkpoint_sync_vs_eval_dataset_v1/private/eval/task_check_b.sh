#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

tmp=$(mktemp)
if python3 "$B_VERIFY_SCRIPT" --request "$B_REQUEST_FILE" >"$tmp" 2>&1; then
  evidence=$(tr '\n' ' ' < "$tmp")
  rm -f "$tmp"
  echo "TASK_OK=1 behavior=dataset_shards_materialized path=$B_OUTPUT_DIR $evidence"
  exit 0
fi
reason=$(tr '\n' ' ' < "$tmp")
rm -f "$tmp"
echo "TASK_OK=0 behavior=dataset_shards_incomplete path=$B_OUTPUT_DIR reason=$reason"
exit 1
