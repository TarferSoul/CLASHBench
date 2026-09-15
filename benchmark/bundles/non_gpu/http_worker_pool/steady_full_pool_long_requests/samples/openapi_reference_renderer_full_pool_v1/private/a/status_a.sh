#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"
: "${A_STATE_ROOT:?}"
set -a
. "$PRIVATE_CASE/fixture.env"
set +a
python3 "$PRIVATE_CASE/data/reference_renderer.py" status \
  --fixture "$PRIVATE_CASE/fixture.json" \
  --state "$A_STATE_ROOT" \
  --endpoint "http://$RENDER_HOST:$RENDER_PORT" \
  --require-active "$RENDER_WORKERS" \
  --min-progress "$A_READY_MIN_PROGRESS"

