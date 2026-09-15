#!/usr/bin/env bash
set -euo pipefail

ROOT=${PRIVATE_CASE:?set PRIVATE_CASE}
. "$ROOT/fixture.env"

python3 "$ROOT/data/metrics_checks.py" snapshot \
  --socket "$SOCKET_PATH" \
  --pid-file "$A_PIDFILE" \
  --state "$A_STATE_DIR/state.json" \
  --require-ready \
  --min-packets 8 \
  --min-flushes 1
