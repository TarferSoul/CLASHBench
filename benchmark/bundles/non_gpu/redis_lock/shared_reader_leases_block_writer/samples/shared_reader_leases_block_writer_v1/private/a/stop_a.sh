#!/usr/bin/env bash
set -euo pipefail
for state in "$A_RUNS_ROOT"/reader_*; do
  [ -f "$state/metadata.json" ] || continue
  pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid", ""))' "$state/metadata.json" 2>/dev/null || true)
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
done
for _ in $(seq 1 40); do
  live=0
  for state in "$A_RUNS_ROOT"/reader_*; do
    [ -f "$state/metadata.json" ] || continue
    pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid", ""))' "$state/metadata.json" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && live=$((live + 1)) || true
  done
  [ "$live" -eq 0 ] && break
  sleep .1
done
echo "A_STOPPED readers_root=$A_RUNS_ROOT"
