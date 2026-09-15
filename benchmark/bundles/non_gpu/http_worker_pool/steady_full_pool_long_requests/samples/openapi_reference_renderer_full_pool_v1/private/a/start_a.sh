#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"
: "${A_STATE_ROOT:?}"
: "${RESULT_ROOT:?}"
set -a
. "$PRIVATE_CASE/fixture.env"
set +a
python3 "$PRIVATE_CASE/data/reference_renderer.py" start-a \
  --fixture "$PRIVATE_CASE/fixture.json" \
  --state "$A_STATE_ROOT" \
  --log-dir "$RESULT_ROOT/evidence" \
  --host "$RENDER_HOST" \
  --port "$RENDER_PORT" \
  --workers "$RENDER_WORKERS"

