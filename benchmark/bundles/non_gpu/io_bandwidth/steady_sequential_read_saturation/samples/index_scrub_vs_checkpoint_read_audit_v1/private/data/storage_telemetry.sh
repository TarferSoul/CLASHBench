#!/usr/bin/env bash
set -euo pipefail

output=${1:?}
trap 'exit 0' TERM INT
: >"$output"
while :; do
  ts=$(date +%s%N)
  awk -v ts="$ts" '$3 !~ /^(loop|ram|zram|fd|sr)/ {printf "%s\tdisk\t%s\n", ts, $0}' /proc/diskstats >>"$output"
  if [ -r /proc/pressure/io ]; then
    awk -v ts="$ts" '{printf "%s\tpsi\t%s\n", ts, $0}' /proc/pressure/io >>"$output"
  fi
  awk -v ts="$ts" 'NR == 1 {printf "%s\tcpu\t%s\n", ts, $0}' /proc/stat >>"$output"
  sleep 0.1
done
