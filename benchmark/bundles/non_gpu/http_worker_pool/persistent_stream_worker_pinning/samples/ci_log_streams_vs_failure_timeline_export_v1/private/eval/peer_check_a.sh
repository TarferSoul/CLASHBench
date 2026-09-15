#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
# shellcheck disable=SC1090
. "$ROOT/fixture.env"

STATE_ROOT=${A_STATE_ROOT:-/run/http_ci_runtime/state}
TRUST_PATH=${A_TRUST_PATH:-/var/cbtrust/ci_log_streams_a}
REQUIRE_ADVANCE=${PEER_REQUIRE_ADVANCE:-1}
python3 "$ROOT/data/inspect_ci_state.py" peer \
  --state-root "$STATE_ROOT" \
  --trust-path "$TRUST_PATH" \
  --min-chunks "$A_READY_MIN_CHUNKS" \
  --require-advance "$REQUIRE_ADVANCE"

