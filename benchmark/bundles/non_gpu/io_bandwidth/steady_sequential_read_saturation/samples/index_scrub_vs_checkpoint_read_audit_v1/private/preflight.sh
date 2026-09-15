#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
set -a
. "$ROOT/fixture.env"
set +a

cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
[ "$cpu_count" -ge "$MIN_CPU_COUNT" ] || { echo "PREFLIGHT_OK=0 reason=cpu_count:$cpu_count"; exit 3; }
mem_available=$(awk '/MemAvailable/ {print $2+0}' /proc/meminfo)
[ "$mem_available" -ge "$MIN_MEMORY_KB" ] || { echo "PREFLIGHT_OK=0 reason=mem_available_kb:$mem_available"; exit 3; }
mkdir -p "$DATA_ROOT"
free_kb=$(df -Pk "$DATA_ROOT" | awk 'NR == 2 {print $4+0}')
[ "$free_kb" -ge "$MIN_FREE_KB" ] || { echo "PREFLIGHT_OK=0 reason=free_kb:$free_kb"; exit 3; }

write_fixture_file() {
  local path=$1 mb=$2 header=$3 footer=$4
  local tmp="${path}.tmp.$$"
  local bytes=$((mb * 1048576))
  rm -f "$tmp"
  dd if=/dev/zero of="$tmp" bs=1M count="$mb" status=none
  printf '%s\n' "$header" | dd of="$tmp" bs=1 seek=0 conv=notrunc status=none
  printf '%s\n' "$footer" | dd of="$tmp" bs=1 seek=$((bytes - 4096)) conv=notrunc status=none
  chmod 0644 "$tmp"
  mv "$tmp" "$path"
}

prepare_group() {
  local dir=$1 catalog=$2 count=$3 mb=$4 prefix=$5 suffix=$6 header_prefix=$7 footer_prefix=$8
  local marker="$dir/.prepared_${count}_${mb}"
  if [ -f "$marker" ] && [ -s "$catalog" ] && [ "$(find "$dir" -maxdepth 1 -type f -name "*.$suffix" | wc -l | tr -d ' ')" = "$count" ]; then
    return 0
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  : >"$catalog.tmp"
  for index in $(seq 0 $((count - 1))); do
    name=$(printf '%s_%02d.%s' "$prefix" "$index" "$suffix")
    header=$(printf '%s%02d_v1' "$header_prefix" "$index")
    footer=$(printf '%s%02d_v1' "$footer_prefix" "$index")
    write_fixture_file "$dir/$name" "$mb" "$header" "$footer"
    bytes=$(stat -c '%s' "$dir/$name")
    printf '%s\t%s\t%s\t%s\n' "$name" "$bytes" "$header" "$footer" >>"$catalog.tmp"
  done
  mv "$catalog.tmp" "$catalog"
  touch "$marker"
}

prepare_group "$A_SEGMENT_ROOT" "$A_CATALOG" "$A_SEGMENT_COUNT" "$A_SEGMENT_MB" \
  "search_segment" "seg" "SEARCH_SEGMENT_HEADER_" "SEARCH_SEGMENT_FOOTER_"
prepare_group "$B_SHARD_ROOT" "$B_CATALOG" "$B_SHARD_COUNT" "$B_SHARD_MB" \
  "checkpoint_shard" "bin" "CHECKPOINT_SHARD_HEADER_" "CHECKPOINT_SHARD_FOOTER_"
sync

a_dev=$(stat -c '%d' "$A_SEGMENT_ROOT")
b_dev=$(stat -c '%d' "$B_SHARD_ROOT")
[ "$a_dev" = "$b_dev" ] || { echo "PREFLIGHT_OK=0 reason=different_filesystems a=$a_dev b=$b_dev"; exit 3; }
echo "PREFLIGHT_OK=1 cpu_count=$cpu_count free_kb=$free_kb a_files=$A_SEGMENT_COUNT b_files=$B_SHARD_COUNT st_dev=$a_dev"
