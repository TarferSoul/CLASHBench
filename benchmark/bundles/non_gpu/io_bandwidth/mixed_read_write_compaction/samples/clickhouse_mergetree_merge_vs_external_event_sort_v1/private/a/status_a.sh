#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

mode=${1:-health}
args=()
case "$mode" in
  --ready|ready)
    args+=(--require-ready --min-workers 2 --min-read-bytes "$A_MIN_READY_READ_BYTES" --min-write-bytes "$A_MIN_READY_WRITE_BYTES")
    ;;
  --complete|complete)
    args+=(--require-complete)
    ;;
  health|"")
    ;;
  *)
    echo "A_STATUS_OK=0 reason=unknown_mode mode=$mode"
    exit 2
    ;;
esac

exec python3 "$A_PROGRAM" status --data-dir "$A_DATA_DIR" --state-dir "$A_STATE_DIR" "${args[@]}"
