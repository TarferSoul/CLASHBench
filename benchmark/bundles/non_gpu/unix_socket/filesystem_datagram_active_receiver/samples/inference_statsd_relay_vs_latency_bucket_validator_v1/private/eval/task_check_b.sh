#!/usr/bin/env bash
set -u

ROOT=${PRIVATE_CASE:?set PRIVATE_CASE}
. "$ROOT/fixture.env"

python3 "$ROOT/data/metrics_checks.py" task-check \
  --socket "$SOCKET_PATH" \
  --ready "$B_READY" \
  --raw "$B_RAW" \
  --summary "$B_SUMMARY" \
  --expected-samples "$B_EXPECTED_SAMPLES" \
  --expected-requests "$B_EXPECTED_REQUESTS" \
  --expected-tokens "$B_EXPECTED_TOKENS" \
  --expected-p95 "$B_EXPECTED_P95_BUCKET" \
  --agent-user "$AGENT_USER" \
  --trust "$TRUST_FILE" \
  --runtime-evidence "${RESULT_ROOT:?set RESULT_ROOT}/evidence/b_runtime_observation.json"
