#!/bin/bash
set -euo pipefail

: "${A_RUNTIME_ROOT:?}" "${A_OUTPUT_ROOT:?}" "${A_SOURCE_FILE:?}" "${A_STATUS_FILE:?}" \
  "${A_PID_FILE:?}" "${A_LOG_PATH:?}" "${A_RETAIN_SEGMENTS:?}"

mkdir -p "$A_RUNTIME_ROOT" "$A_OUTPUT_ROOT"
printf '%s\n' "$$" >"$A_PID_FILE"
awk '{print $22}' "/proc/$$/stat" >"$A_RUNTIME_ROOT/service.start_ticks"
ps -o pgid= -p "$$" | tr -d ' ' >"$A_RUNTIME_ROOT/service.pgid"
chmod 600 "$A_PID_FILE" "$A_RUNTIME_ROOT/service.start_ticks" "$A_RUNTIME_ROOT/service.pgid"

publish_status() {
  local phase=$1 completed=$2 durable_bytes=$3 current=$4 writer_pid=$5 last_rate=$6 current_rate=$7 ledger_inode=$8
  python3 - "$A_STATUS_FILE" "$$" "$phase" "$completed" "$durable_bytes" \
    "$current" "$writer_pid" "$last_rate" "$current_rate" "$ledger_inode" \
    "$(stat -c %d "$A_OUTPUT_ROOT")" "$(awk '{print $22}' "/proc/$$/stat")" <<'PY'
import json
import os
import sys
import time
from pathlib import Path

path, pid, phase, completed, durable, current, writer, last_rate, current_rate, ledger_inode, output_dev, start_ticks = sys.argv[1:]
tmp = Path(path + ".tmp")
tmp.write_text(
    json.dumps(
        {
            "service": "vector-segment-materializer",
            "pid": int(pid),
            "start_ticks": int(start_ticks),
            "phase": phase,
            "completed_segments": int(completed),
            "durable_bytes": int(durable),
            "current_segment": current,
            "writer_pid": int(writer),
            "last_write_mib_per_sec": float(last_rate),
            "current_write_mib_per_sec": float(current_rate),
            "segment_ledger_inode": int(ledger_inode),
            "output_st_dev": int(output_dev),
            "updated_ns": time.time_ns(),
        },
        sort_keys=True,
    )
    + "\n"
)
with tmp.open("rb") as fh:
    os.fsync(fh.fileno())
tmp.replace(path)
PY
}

ledger_path="$A_OUTPUT_ROOT/segment-ledger.tsv"
touch "$ledger_path"
chmod 600 "$ledger_path"

completed=0
durable_bytes=0
last_rate=0
publish_status starting "$completed" "$durable_bytes" none "$$" "$last_rate" 0 "$(stat -c %i "$ledger_path")"

while :; do
  next=$((completed + 1))
  name=$(printf 'vector-segment-%06d.bin' "$next")
  partial="$A_OUTPUT_ROOT/$name.part"
  final="$A_OUTPUT_ROOT/$name"
  rm -f "$partial"
  started_ns=$(date +%s%N)
  publish_status writing "$completed" "$durable_bytes" "$name" "$$" "$last_rate" 0 "$(stat -c %i "$ledger_path")"
  dd if="$A_SOURCE_FILE" of="$partial" bs=4M iflag=fullblock oflag=direct conv=fdatasync status=none
  bytes=$(stat -c %s "$A_SOURCE_FILE")
  mv "$partial" "$final"
  boundary_digest=$({ dd if="$final" bs=1M count=1 status=none; tail -c 1048576 "$final"; } | sha256sum | awk '{print $1}')
  finished_ns=$(date +%s%N)
  elapsed_ms=$(( (finished_ns - started_ns) / 1000000 ))
  [ "$elapsed_ms" -gt 0 ] || elapsed_ms=1
  rate=$(awk -v b="$bytes" -v ms="$elapsed_ms" 'BEGIN {printf "%.3f", b / 1048576 / (ms / 1000)}')
  completed=$next
  durable_bytes=$((durable_bytes + bytes))
  last_rate=$rate
  printf '%s\t%s\t%s\t%s\n' "$completed" "$name" "$bytes" "$boundary_digest" >>"$ledger_path"
  sync -f "$ledger_path"
  publish_status published "$completed" "$durable_bytes" "$name" 0 "$last_rate" 0 "$(stat -c %i "$ledger_path")"
  mapfile -t kept < <(find "$A_OUTPUT_ROOT" -maxdepth 1 -type f -name 'vector-segment-*.bin' -printf '%f\n' | sort)
  while [ "${#kept[@]}" -gt "$A_RETAIN_SEGMENTS" ]; do
    rm -f "$A_OUTPUT_ROOT/${kept[0]}"
    kept=("${kept[@]:1}")
  done
done

