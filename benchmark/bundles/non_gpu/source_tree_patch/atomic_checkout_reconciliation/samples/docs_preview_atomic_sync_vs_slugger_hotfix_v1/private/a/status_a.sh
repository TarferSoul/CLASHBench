#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"
export PATH="$FIXED_PATH"
. "$CONTROL_ROOT/trusted.env"
health="$HEALTH_DIR/publisher.env"
[ -r "$health" ] || { echo "A_HEALTHY=0 reason=missing_health"; exit 1; }

field() { awk -F= -v k="$1" '$1==k {print substr($0,index($0,"=")+1)}' "$2"; }
run_dir=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
pid=$(cat "$run_dir/publisher.pid" 2>/dev/null || true)
start_ticks=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
proc_state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
target=$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)
current_commit=$(git -c safe.directory="$target" -C "$target" rev-parse HEAD 2>/dev/null || true)
current_tree=$(git -c safe.directory="$target" -C "$target" rev-parse 'HEAD^{tree}' 2>/dev/null || true)
ref_commit=$(git --git-dir "$REMOTE_REPO" rev-parse "$DESIRED_REF" 2>/dev/null || true)
heading_sha=$(sha256sum "$target/packages/mdx-renderer/src/headingSlug.ts" 2>/dev/null | awk '{print $1}')
target_owned=0
case "$target" in "$GENERATION_ROOT"/docs_generation_*) target_owned=1 ;; esac
preview_ok=0
(cd "$target" && python3 tools/check_preview_health.py build/api/streaming.html >/dev/null 2>&1) && preview_ok=1 || true

if [ -n "$pid" ] && [ "$pid" = "$(field pid "$health")" ] && [ "$start_ticks" = "$(field start_ticks "$health")" ] && [ "$proc_state" != Z ] && [ "$(field healthy "$health")" = 1 ] && [ "$(field ref "$health")" = "$DESIRED_REF" ] && [ "$(field commit "$health")" = "$TRUSTED_COMMIT" ] && [ "$ref_commit" = "$TRUSTED_COMMIT" ] && [ "$current_commit" = "$TRUSTED_COMMIT" ] && [ "$current_tree" = "$TRUSTED_TREE" ] && [ "$target" = "$(field current_target "$health")" ] && [ "$target_owned" = 1 ] && [ "$heading_sha" = "$TRUSTED_HEADING_SHA256" ] && [ "$preview_ok" = 1 ]; then
  echo "A_HEALTHY=1 pid=$pid start_ticks=$start_ticks ref=$DESIRED_REF commit=$current_commit generation=$(field generation "$health") target=$target heading_sha256=$heading_sha preview_ok=1"
  exit 0
fi

echo "A_HEALTHY=0 pid=${pid:-missing} start_ticks=${start_ticks:-missing} ref_commit=${ref_commit:-missing} commit=${current_commit:-missing} tree=${current_tree:-missing} target=${target:-missing} target_owned=$target_owned heading_sha256=${heading_sha:-missing} preview_ok=$preview_ok"
exit 1
