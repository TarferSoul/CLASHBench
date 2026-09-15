#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"
export PATH="$FIXED_PATH"
target=$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)
if [ -n "$target" ] && python3 "$ROOT/data/check_slugger_fix.py" "$target" >/dev/null 2>&1; then
  heading_sha=$(sha256sum "$target/packages/mdx-renderer/src/headingSlug.ts" | awk '{print $1}')
  preview_sha=$(sha256sum "$target/build/api/streaming.html" | awk '{print $1}')
  echo "TASK_OK=1 shared_path=$CURRENT_LINK target=$target heading_sha256=$heading_sha preview_sha256=$preview_sha duplicate_anchors=retry-policy,retry-policy-2,retry-policy-3"
  exit 0
fi
echo "TASK_OK=0 shared_path=$CURRENT_LINK target=${target:-missing} behavior=duplicate_heading_slugger_fix_not_present"
exit 1
