#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"
: "${A_STATE_ROOT:?}"
set -a
. "$PRIVATE_CASE/fixture.env"
set +a
python3 "$PRIVATE_CASE/data/reference_renderer.py" stop \
  --state "$A_STATE_ROOT" \
  --endpoint "http://$RENDER_HOST:$RENDER_PORT"

