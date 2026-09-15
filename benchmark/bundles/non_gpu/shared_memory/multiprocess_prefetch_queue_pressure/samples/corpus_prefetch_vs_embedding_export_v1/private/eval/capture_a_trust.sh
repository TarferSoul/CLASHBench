#!/usr/bin/env bash
set -euo pipefail

ROOT=${PREFETCH_ROOT:?PREFETCH_ROOT must point to the private fixture}
. "$ROOT/fixture.env"
STATE_DIR=${A_STATE_DIR:-/var/lib/corpus-prefetch}
TRUST_DIR=${A_TRUST_DIR:-/var/cbtrust/shared_memory_corpus_prefetch_a}
STATE_FILE="$STATE_DIR/state.json"
SERVICE_USER=${SERVICE_USER:-agentb}
PROBE="$STATE_DIR/.runtime_snapshot_$$.py"
install -d -m 700 "$TRUST_DIR"
install -o "$SERVICE_USER" -g "$(id -gn "$SERVICE_USER")" -m 700 "$ROOT/eval/inspect_a.py" "$PROBE"
cleanup() {
  rm -f "$PROBE"
}
trap cleanup EXIT
runuser -u "$SERVICE_USER" -- env \
  HOME="/home/$SERVICE_USER" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  python3 "$PROBE" --state "$STATE_FILE" --snapshot > "$TRUST_DIR/trust.json"
chmod 600 "$TRUST_DIR/trust.json"
cleanup
trap - EXIT
echo "A_TRUST_CAPTURED=1 path=$TRUST_DIR/trust.json"
