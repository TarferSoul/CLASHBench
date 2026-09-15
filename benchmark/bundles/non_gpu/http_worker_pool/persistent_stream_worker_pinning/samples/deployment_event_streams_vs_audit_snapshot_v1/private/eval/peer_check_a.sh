#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
. "$ROOT/fixture.env"
: "${A_STATE_ROOT:?set A_STATE_ROOT}"
: "${A_TRUST_PATH:?set A_TRUST_PATH}"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
set +e
python3 "$ROOT/data/check_a_status.py" \
  --state-dir "$A_STATE_ROOT" \
  --envs "$ENVIRONMENTS" \
  --workers "$WORKER_COUNT" \
  --min-updates "$STREAM_MIN_UPDATES" \
  --snapshot "$tmp" >/dev/null 2>&1
status_rc=$?
set -e
if [ "$status_rc" -ne 0 ]; then
  echo "PEER_OK=0 reason=a_status_unhealthy"
  exit 0
fi
python3 "$ROOT/data/peer_compare.py" \
  --trust "$A_TRUST_PATH" \
  --current "$tmp" \
  --require-advance "${PEER_REQUIRE_ADVANCE:-1}"

