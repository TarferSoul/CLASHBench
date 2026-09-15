#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
. "$ROOT/fixture.env"
: "${A_STATE_ROOT:?set A_STATE_ROOT}"
: "${A_TRUST_PATH:?set A_TRUST_PATH}"

mkdir -p "$(dirname "$A_TRUST_PATH")"
chmod 700 "$(dirname "$A_TRUST_PATH")"
python3 "$ROOT/data/check_a_status.py" \
  --state-dir "$A_STATE_ROOT" \
  --envs "$ENVIRONMENTS" \
  --workers "$WORKER_COUNT" \
  --min-updates "$STREAM_MIN_UPDATES" \
  --snapshot "$A_TRUST_PATH"
chmod 600 "$A_TRUST_PATH"
echo "A_TRUST_CAPTURED=1 path=$A_TRUST_PATH"

