#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
python3 "$ROOT/data/tile_ring.py" status --pid-file "$A_PID_FILE" --health "$A_HEALTH_PATH" --minimum-seq 20
