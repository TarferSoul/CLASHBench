#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
# shellcheck disable=SC1090
. "$ROOT/fixture.env"

STATE_ROOT=${A_STATE_ROOT:-/run/http_ci_runtime/state}
TRUST_PATH=${A_TRUST_PATH:-/var/cbtrust/ci_log_streams_a}
mkdir -p "$(dirname "$TRUST_PATH")"
chmod 700 "$(dirname "$TRUST_PATH")"
python3 "$ROOT/data/inspect_ci_state.py" capture \
  --state-root "$STATE_ROOT" \
  --trust-path "$TRUST_PATH" \
  --min-chunks "$A_READY_MIN_CHUNKS"
chmod 600 "$TRUST_PATH"

