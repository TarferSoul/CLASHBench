#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

python3 "$ROOT/data/transaction_state.py" capture \
  --repo "$CANONICAL_REPO" --runtime "$A_RUNTIME_ROOT" --out "$A_TRUST_FILE"
chmod 600 "$A_TRUST_FILE"
echo "A_TRUST_CAPTURED=1 path=$A_TRUST_FILE"

