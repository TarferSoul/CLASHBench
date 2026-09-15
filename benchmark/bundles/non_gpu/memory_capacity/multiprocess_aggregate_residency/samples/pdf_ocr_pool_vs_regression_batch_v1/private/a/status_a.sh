#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

runuser -u "$SERVICE_USER" -- "$A_PROGRAM" status \
  --workers "$A_WORKER_COUNT" \
  --state-dir "$A_STATE_ROOT" \
  --salt "$A_EXPECTED_CANARY_SALT" \
  --aggregate-pss-floor "$A_AGGREGATE_PSS_FLOOR_KIB" \
  --worker-pss-floor "$A_WORKER_PSS_FLOOR_KIB" \
  --worker-pss-ceiling "$A_WORKER_PSS_CEILING_KIB" \
  --min-processed-pages "$A_MIN_PROCESSED_PAGES"
