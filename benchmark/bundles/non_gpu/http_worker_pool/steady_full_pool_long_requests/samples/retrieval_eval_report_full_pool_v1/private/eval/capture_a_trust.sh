#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"
: "${A_STATE_ROOT:?}"
: "${A_TRUST_PATH:?}"
set -a
. "$PRIVATE_CASE/fixture.env"
set +a
python3 "$PRIVATE_CASE/data/retrieval_report_service.py" capture-trust \
  --fixture "$PRIVATE_CASE/fixture.json" \
  --state "$A_STATE_ROOT" \
  --trust-path "$A_TRUST_PATH"

