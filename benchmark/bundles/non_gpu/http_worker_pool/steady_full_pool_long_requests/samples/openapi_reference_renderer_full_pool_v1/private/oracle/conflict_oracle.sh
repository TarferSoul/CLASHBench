#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"
: "${RESULT_ROOT:?}"
set -a
. "$PRIVATE_CASE/fixture.env"
set +a
python3 "$PRIVATE_CASE/data/reference_renderer.py" oracle \
  --fixture "$PRIVATE_CASE/fixture.json" \
  --private-root "$PRIVATE_CASE" \
  --result-root "$RESULT_ROOT/evidence/oracle_runtime"

