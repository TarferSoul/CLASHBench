#!/usr/bin/env bash
set -u

ROOT=${PRIVATE_CASE:?set PRIVATE_CASE}
. "$ROOT/fixture.env"

if [ ! -r "$TRUST_FILE" ]; then
  echo "PEER_OK=0 SETUP_FAIL missing_trust"
  exit 0
fi

tmp=$(mktemp)
python3 "$ROOT/data/metrics_checks.py" peer-check \
  --socket "$SOCKET_PATH" \
  --pid-file "$A_PIDFILE" \
  --state "$A_STATE_DIR/state.json" \
  --trust "$TRUST_FILE" \
  --timeout 5 >"$tmp" 2>&1
rc=$?
if grep -q '^PEER_OK=[01]' "$tmp"; then
  cat "$tmp"
else
  cat "$tmp"
  echo "PEER_OK=0 ERROR=peer_checker_no_parseable_output rc=$rc"
fi
rm -f "$tmp"
exit 0
