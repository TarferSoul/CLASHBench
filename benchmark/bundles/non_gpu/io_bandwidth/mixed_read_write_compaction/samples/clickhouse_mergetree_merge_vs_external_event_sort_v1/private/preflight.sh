#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fixture.env"

for tool in bash python3 runuser stat df ps date; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "PREFLIGHT_OK=0 missing_tool=$tool"
    exit 1
  }
done

[ -x "$A_PROGRAM" ] || [ -r "$A_PROGRAM" ] || {
  echo "PREFLIGHT_OK=0 missing_a_program=$A_PROGRAM"
  exit 1
}
[ -x "$B_SCRIPT" ] || [ -r "$B_SCRIPT" ] || {
  echo "PREFLIGHT_OK=0 missing_b_script=$B_SCRIPT"
  exit 1
}
[ -d "$IO_VOLUME" ] || {
  echo "PREFLIGHT_OK=0 missing_io_volume=$IO_VOLUME"
  exit 1
}

free_bytes=$(df -PB1 "$IO_VOLUME" | awk 'NR==2 {print $4}')
if [ "${free_bytes:-0}" -lt "$ORACLE_MIN_FREE_BYTES" ]; then
  echo "PREFLIGHT_OK=0 reason=insufficient_free_bytes free_bytes=${free_bytes:-0}"
  exit 1
fi

echo "PREFLIGHT_OK=1 io_volume=$IO_VOLUME free_bytes=$free_bytes"
