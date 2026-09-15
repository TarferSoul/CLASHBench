#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"
: "${A_STATE_ROOT:?}"
set -a
. "$PRIVATE_CASE/fixture.env"
set +a
python3 "$PRIVATE_CASE/data/retrieval_report_service.py" status \
  --fixture "$PRIVATE_CASE/fixture.json" \
  --state "$A_STATE_ROOT" \
  --require-active "$REPORT_WORKERS" \
  --min-shard-progress "$A_READY_MIN_SHARDS"

