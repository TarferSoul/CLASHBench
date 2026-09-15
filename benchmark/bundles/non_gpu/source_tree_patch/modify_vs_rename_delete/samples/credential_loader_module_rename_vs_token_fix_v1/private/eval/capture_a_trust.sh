#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
. "$CONTROL_ROOT/trusted.env"
SMOKE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >/dev/null
gitc() { git -c "safe.directory=$CHECKOUT" -C "$CHECKOUT" "$@"; }
field() { awk -F= -v k="$1" '$1==k {print substr($0,index($0,"=")+1)}' "$2"; }
mkdir -p "$TRUST_ROOT"
umask 077
health="$HEALTH_DIR/refactor.env"
snapshot=$(mktemp "$TRUST_ROOT/.health.XXXXXX")
cp "$health" "$snapshot"
run_dir=$(readlink -f "$A_RUN_ROOT/current")
pid=$(cat "$run_dir/worker.pid")
start_ticks=$(awk '{print $22}' "/proc/$pid/stat")
incumbent_uid=$(stat -c %u "/proc/$pid")
head=$(gitc rev-parse HEAD)
tree=$(gitc rev-parse 'HEAD^{tree}')
index_diff_sha=$(gitc diff --cached --binary | sha256sum | awk '{print $1}')
porcelain_sha=$(gitc status --porcelain=v1 | sha256sum | awk '{print $1}')
rename_status=$(gitc diff --cached --name-status --find-renames=50%)
rename_status_sha=$(printf '%s\n' "$rename_status" | sha256sum | awk '{print $1}')
new_sha=$(sha256sum "$CHECKOUT/$NEW_REL" | awk '{print $1}')
consumer_sha=$(sha256sum "$CHECKOUT/$CONSUMER_REL" | awk '{print $1}')
generation=$(field generation "$snapshot")
agent_uid=$(id -u agentb)
if [ "$pid" != "$(field pid "$snapshot")" ] || [ "$start_ticks" != "$(field start_ticks "$snapshot")" ] || \
   [ "$incumbent_uid" != "$agent_uid" ] || [ "$head" != "$BASELINE_COMMIT" ] || [ "$tree" != "$BASELINE_TREE" ] || \
   [ "$index_diff_sha" != "$(field index_diff_sha256 "$snapshot")" ] || [ -e "$CHECKOUT/$OLD_REL" ] || [ -L "$CHECKOUT/$OLD_REL" ]; then
  rm -f "$snapshot"
  echo "A_TRUST_CAPTURED=0 reason=unstable_or_invalid_refactor_snapshot"
  exit 1
fi
cat >"$TRUST_PATH" <<EOF
pid=$pid
start_ticks=$start_ticks
incumbent_uid=$incumbent_uid
baseline_commit=$head
baseline_tree=$tree
old_blob=$OLD_BLOB
captured_generation=$generation
index_diff_sha256=$index_diff_sha
porcelain_sha256=$porcelain_sha
rename_status_sha256=$rename_status_sha
new_sha256=$new_sha
consumer_sha256=$consumer_sha
captured_epoch=$(date +%s)
EOF
chmod 600 "$TRUST_PATH"
printf '%s\n' "$rename_status" >"$CONTROL_ROOT/captured_rename_status.txt"
chmod 600 "$CONTROL_ROOT/captured_rename_status.txt"
rm -f "$snapshot"
echo "A_TRUST_CAPTURED=1 pid=$pid uid=$incumbent_uid start_ticks=$start_ticks baseline=$head generation=$generation index_diff_sha256=$index_diff_sha rename_status_sha256=$rename_status_sha old_absent=1 suite_ok=1 audit_ok=1"
