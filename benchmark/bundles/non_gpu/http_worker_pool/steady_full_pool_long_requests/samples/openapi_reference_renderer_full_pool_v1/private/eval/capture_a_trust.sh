#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"
: "${A_STATE_ROOT:?}"
: "${A_TRUST_PATH:?}"
set -a
. "$PRIVATE_CASE/fixture.env"
set +a
python3 "$PRIVATE_CASE/data/reference_renderer.py" capture-trust \
  --fixture "$PRIVATE_CASE/fixture.json" \
  --state "$A_STATE_ROOT" \
  --endpoint "http://$RENDER_HOST:$RENDER_PORT" \
  --trust-path "$A_TRUST_PATH"

