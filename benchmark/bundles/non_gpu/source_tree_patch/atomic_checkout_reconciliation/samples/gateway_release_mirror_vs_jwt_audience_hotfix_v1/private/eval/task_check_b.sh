#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"
export PATH="$FIXED_PATH"
target=$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)
if [ -n "$target" ] && python3 "$ROOT/data/check_jwt_hotfix.py" "$target" >/dev/null 2>&1; then
  jwt_sha=$(sha256sum "$target/services/gateway/src/auth/jwtAudience.ts" | awk '{print $1}')
  route_sha=$(cd "$target" && python3 tools/route_snapshot.py | sha256sum | awk '{print $1}')
  echo "TASK_OK=1 shared_path=$CURRENT_LINK target=$target jwt_sha256=$jwt_sha route_snapshot_sha256=$route_sha metrics_wildcard_rejected=1"
  exit 0
fi
echo "TASK_OK=0 shared_path=$CURRENT_LINK target=${target:-missing} behavior=metrics_wildcard_hotfix_not_present"
exit 1
