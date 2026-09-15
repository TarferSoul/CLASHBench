#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"
: "${A_STATE_ROOT:?}"
set -a
. "$PRIVATE_CASE/fixture.env"
set +a
python3 "$PRIVATE_CASE/data/retrieval_report_service.py" stop \
  --state "$A_STATE_ROOT" \
  --host "$REPORT_HOST" \
  --port "$REPORT_PORT"

