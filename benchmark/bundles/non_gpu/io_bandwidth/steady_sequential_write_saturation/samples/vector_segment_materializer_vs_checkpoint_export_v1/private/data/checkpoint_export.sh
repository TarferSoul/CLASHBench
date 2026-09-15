#!/bin/bash
set -euo pipefail

source_file=
expected_file=
output_root=
deadline_ms=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) source_file=$2; shift 2 ;;
    --expected-sha256-file) expected_file=$2; shift 2 ;;
    --output) output_root=$2; shift 2 ;;
    --deadline-ms) deadline_ms=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -f "$source_file" ] || { echo "source tensor snapshot is missing" >&2; exit 2; }
[ -f "$expected_file" ] || { echo "expected checksum is missing" >&2; exit 2; }
[ -n "$output_root" ] || { echo "--output is required" >&2; exit 2; }

mkdir -p "$output_root"
rm -f "$output_root/model-shard.bin.part" "$output_root/model-shard.bin" \
  "$output_root/SHA256SUMS" "$output_root/SHA256SUMS.part" "$output_root/checkpoint-export.json"

expected=$(awk 'NR==1 {print $1}' "$expected_file")
bytes=$(stat -c %s "$source_file")
source_dev=$(stat -c %d "$source_file")
dest_dev=$(stat -c %d "$output_root")
started_ns=$(date +%s%N)

dd if="$source_file" of="$output_root/model-shard.bin.part" bs=4M iflag=fullblock \
  oflag=direct conv=fdatasync status=none
copy_finished_ns=$(date +%s%N)
mv "$output_root/model-shard.bin.part" "$output_root/model-shard.bin"
actual=$(sha256sum "$output_root/model-shard.bin" | awk '{print $1}')
[ "$actual" = "$expected" ] || { echo "copied tensor checksum mismatch" >&2; exit 3; }
printf '%s  %s\n' "$actual" model-shard.bin >"$output_root/SHA256SUMS.part"
mv "$output_root/SHA256SUMS.part" "$output_root/SHA256SUMS"
python3 - "$output_root" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
finished_ns=$(date +%s%N)
copy_elapsed_ms=$(( (copy_finished_ns - started_ns) / 1000000 ))
total_elapsed_ms=$(( (finished_ns - started_ns) / 1000000 ))
deadline_met=1
if [ "$deadline_ms" -gt 0 ] && [ "$total_elapsed_ms" -gt "$deadline_ms" ]; then deadline_met=0; fi

python3 - "$output_root/checkpoint-export.json" "$bytes" "$expected" "$source_dev" "$dest_dev" \
  "$copy_elapsed_ms" "$total_elapsed_ms" "$deadline_ms" "$deadline_met" <<'PY'
import json
from pathlib import Path
import sys
import time

path, size, digest, source_dev, dest_dev, copy_ms, total_ms, deadline_ms, deadline_met = sys.argv[1:]
Path(path).write_text(json.dumps({
    "artifact": "model-shard.bin",
    "bytes": int(size),
    "sha256": digest,
    "source_st_dev": int(source_dev),
    "destination_st_dev": int(dest_dev),
    "direct_write_block_mib": 4,
    "durability": "O_DIRECT plus fdatasync and directory fsync",
    "copy_elapsed_ms": int(copy_ms),
    "total_elapsed_ms": int(total_ms),
    "deadline_ms": int(deadline_ms),
    "deadline_met": bool(int(deadline_met)),
    "completed_at_ns": time.time_ns(),
}, sort_keys=True, indent=2) + "\n")
PY
python3 - "$output_root" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
printf 'CHECKPOINT_EXPORT_COMPLETE=1 BYTES=%s COPY_ELAPSED_MS=%s TOTAL_ELAPSED_MS=%s DEADLINE_MET=%s\n' \
  "$bytes" "$copy_elapsed_ms" "$total_elapsed_ms" "$deadline_met"
[ "$deadline_met" = 1 ] || exit 75

