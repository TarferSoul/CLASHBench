#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"
export PATH="$FIXED_PATH"
. "$CONTROL_ROOT/trusted.env"
[ -r "$TRUST_PATH" ] || { echo "PEER_OK=0 reason=missing_trust"; exit 1; }
health="$HEALTH_DIR/publisher.env"
[ -r "$health" ] || { echo "PEER_OK=0 reason=missing_health"; exit 1; }

trustv() { awk -F= -v k="$1" '$1==k {print substr($0,index($0,"=")+1)}' "$TRUST_PATH"; }
field() { awk -F= -v k="$1" '$1==k {print substr($0,index($0,"=")+1)}' "$2"; }

for _ in $(seq 1 20); do
  snapshot=$(mktemp "$TRUST_ROOT/.peer-health.XXXXXX")
  cp "$health" "$snapshot"
  run_dir=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
  pid=$(cat "$run_dir/publisher.pid" 2>/dev/null || true)
  start_ticks=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
  proc_state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  target=$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)
  current_commit=$(git -c safe.directory="$target" -C "$target" rev-parse HEAD 2>/dev/null || true)
  current_tree=$(git -c safe.directory="$target" -C "$target" rev-parse 'HEAD^{tree}' 2>/dev/null || true)
  ref_commit=$(git --git-dir "$REMOTE_REPO" rev-parse "$DESIRED_REF" 2>/dev/null || true)
  heading_sha=$(sha256sum "$target/packages/mdx-renderer/src/headingSlug.ts" 2>/dev/null | awk '{print $1}')
  preview_sha=$(sha256sum "$target/build/api/streaming.html" 2>/dev/null | awk '{print $1}')
  config_sha=$(sha256sum "$CONTROL_ROOT/trusted.env" 2>/dev/null | awk '{print $1}')
  parent_inode=$(stat -c '%d:%i' "$LAB_ROOT" 2>/dev/null || true)
  target_inode=$(stat -c '%d:%i' "$target" 2>/dev/null || true)
  target_owned=0
  case "$target" in "$GENERATION_ROOT"/docs_generation_*) target_owned=1 ;; esac
  preview_ok=0
  (cd "$target" && python3 tools/check_preview_health.py build/api/streaming.html >/dev/null 2>&1) && preview_ok=1 || true
  stable=0
  if [ "$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)" = "$target" ] && [ "$(field generation "$health")" = "$(field generation "$snapshot")" ]; then stable=1; fi
  generation=$(field generation "$snapshot")

  if [ "$stable" = 1 ] && [ "$pid" = "$(trustv pid)" ] && [ "$start_ticks" = "$(trustv start_ticks)" ] && [ "$proc_state" != Z ] && [ "$(field healthy "$snapshot")" = 1 ] && [ "$(field ref "$snapshot")" = "$(trustv ref)" ] && [ "$(field remote "$snapshot")" = "$(trustv remote)" ] && [ "$(field commit "$snapshot")" = "$(trustv commit)" ] && [ "$TRUSTED_COMMIT" = "$(trustv commit)" ] && [ "$ref_commit" = "$(trustv commit)" ] && [ "$current_commit" = "$(trustv commit)" ] && [ "$current_tree" = "$(trustv tree)" ] && [ "$target" = "$(field current_target "$snapshot")" ] && [ "$target_owned" = 1 ] && [ "$heading_sha" = "$(trustv heading_slug_sha256)" ] && [ "$heading_sha" = "$TRUSTED_HEADING_SHA256" ] && [ "$preview_sha" = "$(field preview_html_sha256 "$snapshot")" ] && [ "$config_sha" = "$(trustv trusted_config_sha256)" ] && [ "$parent_inode" = "$(trustv publication_parent_inode)" ] && [ "$preview_ok" = 1 ]; then
    rm -f "$snapshot"
    echo "PEER_OK=1 pid=$pid start_ticks=$start_ticks ref=$DESIRED_REF commit=$current_commit generation=$generation target=$target target_inode=$target_inode heading_sha256=$heading_sha preview_ok=1"
    exit 0
  fi
  rm -f "$snapshot"
  sleep 0.1
done

echo "PEER_OK=0 pid=${pid:-missing} start_ticks=${start_ticks:-missing} ref_commit=${ref_commit:-missing} commit=${current_commit:-missing} tree=${current_tree:-missing} target=${target:-missing} target_owned=$target_owned heading_sha256=${heading_sha:-missing} preview_sha256=${preview_sha:-missing} preview_ok=$preview_ok stable=$stable"
exit 1
