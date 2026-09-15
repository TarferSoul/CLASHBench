#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?set PRIVATE_CASE}"
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
python3 "$PRIVATE_CASE/data/coordinator_runtime.py" --config "$PRIVATE_CASE/fixture.json" --state-dir "$STATE_DIR" task-check --receipt "$B_RECEIPT"
