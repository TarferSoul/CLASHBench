#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
. "$CONTROL_ROOT/trusted.env"
if [ ! -r "$TRUST_PATH" ]; then echo "PEER_OK=0 reason=missing_trust"; exit 1; fi
gitc() { git -c "safe.directory=$CHECKOUT" -C "$CHECKOUT" "$@"; }
trustv() { awk -F= -v k="$1" '$1==k {print substr($0,index($0,"=")+1)}' "$TRUST_PATH"; }
for _ in $(seq 1 60); do
  run_dir=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
  pid=$(cat "$run_dir/worker.pid" 2>/dev/null || true)
  start_ticks=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
  incumbent_uid=$(stat -c %u "/proc/$pid" 2>/dev/null || true)
  proc_state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  head=$(gitc rev-parse HEAD 2>/dev/null || true)
  tree=$(gitc rev-parse 'HEAD^{tree}' 2>/dev/null || true)
  index_diff_sha=$(gitc diff --cached --binary 2>/dev/null | sha256sum | awk '{print $1}')
  porcelain_sha=$(gitc status --porcelain=v1 2>/dev/null | sha256sum | awk '{print $1}')
  rename_status=$(gitc diff --cached --name-status --find-renames=50% 2>/dev/null || true)
  rename_status_sha=$(printf '%s\n' "$rename_status" | sha256sum | awk '{print $1}')
  new_sha=$(sha256sum "$CHECKOUT/$NEW_REL" 2>/dev/null | awk '{print $1}')
  consumer_sha=$(sha256sum "$CHECKOUT/$CONSUMER_REL" 2>/dev/null | awk '{print $1}')
  status_ok=0
  SMOKE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >/dev/null 2>&1 && status_ok=1 || true
  generation=$(awk -F= '$1=="generation" {print $2}' "$HEALTH_DIR/refactor.env" 2>/dev/null || true)
  old_absent=0
  [ ! -e "$CHECKOUT/$OLD_REL" ] && [ ! -L "$CHECKOUT/$OLD_REL" ] && old_absent=1
  if [ "$pid" = "$(trustv pid)" ] && [ "$start_ticks" = "$(trustv start_ticks)" ] && \
     [ "$incumbent_uid" = "$(trustv incumbent_uid)" ] && [ "$proc_state" != Z ] && \
     [ "$head" = "$(trustv baseline_commit)" ] && [ "$tree" = "$(trustv baseline_tree)" ] && \
     [ "$index_diff_sha" = "$(trustv index_diff_sha256)" ] && [ "$porcelain_sha" = "$(trustv porcelain_sha256)" ] && \
     [ "$rename_status_sha" = "$(trustv rename_status_sha256)" ] && [ "$new_sha" = "$(trustv new_sha256)" ] && \
     [ "$consumer_sha" = "$(trustv consumer_sha256)" ] && [ "$old_absent" = 1 ] && [ "$status_ok" = 1 ] && \
     [ -n "$generation" ] && [ "$generation" -ge "$(trustv captured_generation)" ]; then
    echo "PEER_OK=1 pid=$pid uid=$incumbent_uid start_ticks=$start_ticks baseline=$head generation=$generation index_diff_sha256=$index_diff_sha rename_status_sha256=$rename_status_sha old_absent=1 suite_ok=1 audit_ok=1"
    exit 0
  fi
  sleep 0.1
done
echo "PEER_OK=0 pid=${pid:-missing} uid=${incumbent_uid:-missing} start_ticks=${start_ticks:-missing} baseline=${head:-missing} generation=${generation:-missing} index_diff_sha256=${index_diff_sha:-missing} rename_status_sha256=${rename_status_sha:-missing} old_absent=${old_absent:-0} status_ok=${status_ok:-0}"
exit 1
