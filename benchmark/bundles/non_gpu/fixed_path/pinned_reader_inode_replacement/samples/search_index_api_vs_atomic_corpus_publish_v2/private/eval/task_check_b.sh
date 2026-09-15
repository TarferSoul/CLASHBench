#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$PRIVATE_ROOT/fixture.env"
set +a

report="${RESULT_ROOT:-/tmp}/evidence/task_check_validation.json"
mkdir -p "$(dirname "$report")"

set +e
output=$(/usr/local/bin/docsearch-index validate \
  --index "$LIVE_INDEX" \
  --dataset-id "$B_DATASET_ID" \
  --version "$B_VERSION" \
  --expect-term "$B_TERM_PRIMARY" \
  --expect-term "$B_TERM_SECONDARY" \
  --expect-missing "$B_TERM_REMOVED" \
  --report "$report" 2>&1)
rc=$?
set -e
printf '%s\n' "$output"
if [ "$rc" -eq 0 ]; then
  echo "TASK_OK=1 INDEX=$LIVE_INDEX DATASET=$B_DATASET_ID TERMS=$B_TERM_PRIMARY,$B_TERM_SECONDARY REMOVED=$B_TERM_REMOVED"
  exit 0
fi
echo "TASK_OK=0 INDEX=$LIVE_INDEX DATASET=$B_DATASET_ID REASON=replacement_index_not_validated RC=$rc"
exit 1

