#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

python3 "$ROOT/data/transaction_state.py" peer \
  --repo "$CANONICAL_REPO" --runtime "$A_RUNTIME_ROOT" --trust "$A_TRUST_FILE" \
  --expected-shards "$CATALOG_SHARDS" --records-per-shard "$CATALOG_RECORDS_PER_SHARD"

