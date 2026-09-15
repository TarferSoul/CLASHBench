#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
# shellcheck disable=SC1090
. "$ROOT/fixture.env"

STATE_ROOT=${A_STATE_ROOT:-/run/http_ci_runtime/state}
python3 "$ROOT/data/inspect_ci_state.py" status \
  --state-root "$STATE_ROOT" \
  --min-chunks "$A_READY_MIN_CHUNKS"

