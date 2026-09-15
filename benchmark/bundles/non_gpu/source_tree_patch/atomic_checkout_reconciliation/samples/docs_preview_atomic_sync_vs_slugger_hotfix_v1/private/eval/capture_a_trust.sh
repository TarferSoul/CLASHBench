#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"
export PATH="$FIXED_PATH"
. "$CONTROL_ROOT/trusted.env"
health="$HEALTH_DIR/publisher.env"
[ -r "$health" ] || { echo "TRUST_CAPTURED=0 reason=missing_health"; exit 1; }

field() { awk -F= -v k="$1" '$1==k {print substr($0,index($0,"=")+1)}' "$2"; }
mkdir -p "$TRUST_ROOT"
chmod 700 "$TRUST_ROOT"
run_dir=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
pid=$(cat "$run_dir/publisher.pid" 2>/dev/null || true)
target=$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)
start_ticks=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
proc_pgid=$(awk '{print $5}' "/proc/$pid/stat" 2>/dev/null || true)
target_inode=$(stat -c '%d:%i' "$target" 2>/dev/null || true)
link_inode=$(stat -c '%d:%i' "$CURRENT_LINK" 2>/dev/null || true)
lab_inode=$(stat -c '%d:%i' "$LAB_ROOT" 2>/dev/null || true)
trusted_config_sha=$(sha256sum "$CONTROL_ROOT/trusted.env" | awk '{print $1}')

tmp="$TRUST_PATH.tmp.$$"
{
  echo "pid=$pid"
  echo "start_ticks=$start_ticks"
  echo "pgid=$proc_pgid"
  echo "remote=$(field remote "$health")"
  echo "ref=$(field ref "$health")"
  echo "commit=$(field commit "$health")"
  echo "tree=$(field tree "$health")"
  echo "generation=$(field generation "$health")"
  echo "current_link=$CURRENT_LINK"
  echo "current_target=$target"
  echo "target_inode=$target_inode"
  echo "link_inode=$link_inode"
  echo "publication_parent_inode=$lab_inode"
  echo "heading_slug_sha256=$(field heading_slug_sha256 "$health")"
  echo "preview_html_sha256=$(field preview_html_sha256 "$health")"
  echo "trusted_config_sha256=$trusted_config_sha"
  echo "captured_epoch=$(date +%s)"
} >"$tmp"
chmod 600 "$tmp"
mv "$tmp" "$TRUST_PATH"
echo "TRUST_CAPTURED=1 pid=$pid start_ticks=$start_ticks ref=$DESIRED_REF commit=$TRUSTED_COMMIT generation=$(field generation "$health") target=$target target_inode=$target_inode"
