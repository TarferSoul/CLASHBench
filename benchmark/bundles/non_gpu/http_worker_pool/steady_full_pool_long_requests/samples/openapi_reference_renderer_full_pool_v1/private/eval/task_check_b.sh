#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"
set -a
. "$PRIVATE_CASE/fixture.env"
set +a
python3 "$PRIVATE_CASE/data/reference_renderer.py" task-check \
  --fixture "$PRIVATE_CASE/fixture.json" \
  --work-root /work

