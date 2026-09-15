#!/usr/bin/env bash
set -euo pipefail

ROOT=${PRIVATE_CASE:?set PRIVATE_CASE}
. "$ROOT/fixture.env"

install -d -o root -g root -m 0700 "$TRUST_DIR"
python3 "$ROOT/data/metrics_checks.py" capture-trust \
  --socket "$SOCKET_PATH" \
  --pid-file "$A_PIDFILE" \
  --state "$A_STATE_DIR/state.json" \
  --out "$TRUST_FILE" \
  --timeout 5
