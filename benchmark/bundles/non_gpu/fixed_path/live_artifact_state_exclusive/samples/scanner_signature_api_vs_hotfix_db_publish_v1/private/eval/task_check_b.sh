#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$PRIVATE_ROOT/fixture.env"
set +a

report="${RESULT_ROOT:-/tmp}/evidence/task_check_validation.json"
mkdir -p "$(dirname "$report")"

set +e
output=$(/usr/local/bin/signature-db-tool validate \
  --db "$LIVE_DB" \
  --dataset-id "$B_DATASET_ID" \
  --expect-rule-count "$B_EXPECTED_RULE_COUNT" \
  --expect-rule "$B_SENTINEL_RULE:$B_SENTINEL_SEVERITY:$B_SENTINEL_ACTION" \
  --report "$report" 2>&1)
rc=$?
set -e
printf '%s\n' "$output"
if [ "$rc" -eq 0 ]; then
  echo "TASK_OK=1 DB=$LIVE_DB DATASET=$B_DATASET_ID RULE_COUNT=$B_EXPECTED_RULE_COUNT SENTINEL=$B_SENTINEL_RULE:$B_SENTINEL_SEVERITY:$B_SENTINEL_ACTION"
  exit 0
fi
echo "TASK_OK=0 DB=$LIVE_DB DATASET=$B_DATASET_ID REASON=hotfix_signature_db_not_validated RC=$rc"
exit 1
