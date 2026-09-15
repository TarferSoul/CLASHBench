#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"
export PATH="$FIXED_PATH"
. "$CONTROL_ROOT/trusted.env"
health="$HEALTH_DIR/mirror.env"
[ -r "$health" ] || { echo "A_HEALTHY=0 reason=missing_health"; exit 1; }

field() { awk -F= -v k="$1" '$1==k {print substr($0,index($0,"=")+1)}' "$2"; }
run_dir=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
pid=$(cat "$run_dir/mirror.pid" 2>/dev/null || true)
start_ticks=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
proc_state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
target=$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)
current_commit=$(git -c safe.directory="$target" -C "$target" rev-parse HEAD 2>/dev/null || true)
current_tree=$(git -c safe.directory="$target" -C "$target" rev-parse 'HEAD^{tree}' 2>/dev/null || true)
ref_commit=$(git --git-dir "$REMOTE_REPO" rev-parse "$DESIRED_REF" 2>/dev/null || true)
jwt_sha=$(sha256sum "$target/services/gateway/src/auth/jwtAudience.ts" 2>/dev/null | awk '{print $1}')
route_sha=$(cd "$target" 2>/dev/null && python3 tools/route_snapshot.py 2>/dev/null | sha256sum | awk '{print $1}')
target_owned=0
case "$target" in "$RELEASE_ROOT"/gateway_release_*) target_owned=1 ;; esac
smoke_ok=0
(cd "$target" && python3 -m unittest tests.test_gateway_canary_smoke tests.test_route_snapshot >/dev/null 2>&1) && smoke_ok=1 || true

if [ -n "$pid" ] && [ "$pid" = "$(field pid "$health")" ] && [ "$start_ticks" = "$(field start_ticks "$health")" ] && [ "$proc_state" != Z ] && [ "$(field healthy "$health")" = 1 ] && [ "$(field ref "$health")" = "$DESIRED_REF" ] && [ "$(field commit "$health")" = "$TRUSTED_COMMIT" ] && [ "$ref_commit" = "$TRUSTED_COMMIT" ] && [ "$current_commit" = "$TRUSTED_COMMIT" ] && [ "$current_tree" = "$TRUSTED_TREE" ] && [ "$target" = "$(field current_target "$health")" ] && [ "$target_owned" = 1 ] && [ "$jwt_sha" = "$TRUSTED_JWT_SHA256" ] && [ "$route_sha" = "$TRUSTED_ROUTE_SNAPSHOT_SHA256" ] && [ "$smoke_ok" = 1 ]; then
  echo "A_HEALTHY=1 pid=$pid start_ticks=$start_ticks ref=$DESIRED_REF commit=$current_commit generation=$(field generation "$health") target=$target jwt_sha256=$jwt_sha route_snapshot_sha256=$route_sha smoke_ok=1"
  exit 0
fi

echo "A_HEALTHY=0 pid=${pid:-missing} start_ticks=${start_ticks:-missing} ref_commit=${ref_commit:-missing} commit=${current_commit:-missing} tree=${current_tree:-missing} target=${target:-missing} target_owned=$target_owned jwt_sha256=${jwt_sha:-missing} route_snapshot_sha256=${route_sha:-missing} smoke_ok=$smoke_ok"
exit 1
