#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
bash "$CASE_PRIVATE_ROOT/a/stop_a.sh"
[ "$A_OUTPUT_DIR" = "/dev/shm/android_release_9.4.0_symbols" ] || exit 2
before=$(du -s -B1 "$A_OUTPUT_DIR" | awk '{print $1}')
rm -rf -- "$A_OUTPUT_DIR"
sync -f "$VOLUME_ROOT" 2>/dev/null || true
echo "A_RELEASE_OK=1 released_allocated_bytes=$before path=$A_OUTPUT_DIR"
