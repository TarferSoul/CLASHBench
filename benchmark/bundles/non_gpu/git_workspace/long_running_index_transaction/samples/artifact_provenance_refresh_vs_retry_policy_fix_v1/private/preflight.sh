#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"

command -v git >/dev/null
command -v python3 >/dev/null
command -v runuser >/dev/null
test -d "$CANONICAL_REPO/.git"
test ! -e "$A_LOCK_PATH"
[ "$(runuser -u agentb -- git -C "$CANONICAL_REPO" branch --show-current)" = "$B_BRANCH" ]
[ -z "$(runuser -u agentb -- git -C "$CANONICAL_REPO" status --porcelain)" ]
[ "$(find "$CANONICAL_REPO/registry/provenance" -maxdepth 1 -type f -name 'manifest_*.jsonl' | wc -l)" -eq "$CATALOG_SHARDS" ]
test ! -e "$CANONICAL_REPO/.gitattributes"
python3 -m py_compile "$CANONICAL_REPO/tools/prepare_provenance.py" \
  "$CANONICAL_REPO/tools/provenance_clean.py" "$CANONICAL_REPO/tools/validate_staged_provenance.py"
echo "PREFLIGHT_OK=1 branch=$B_BRANCH provenance_shards=$CATALOG_SHARDS records_per_shard=$CATALOG_RECORDS_PER_SHARD"
