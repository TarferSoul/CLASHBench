#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
. "$ROOT/fixture.env"
: "${A_STATE_ROOT:?set A_STATE_ROOT}"

python3 "$ROOT/data/check_a_status.py" \
  --state-dir "$A_STATE_ROOT" \
  --envs "$ENVIRONMENTS" \
  --workers "$WORKER_COUNT" \
  --min-updates "$STREAM_MIN_UPDATES"

