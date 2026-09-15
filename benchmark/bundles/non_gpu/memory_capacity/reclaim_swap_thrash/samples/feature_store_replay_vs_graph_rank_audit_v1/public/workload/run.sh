#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CPU=$(cat "$ROOT/cpu_id.txt")
exec taskset -c "$CPU" python3 "$ROOT/run_graph_rank.py" \
  --plan "$ROOT/graph_plan.json" \
  --input "$ROOT/input/edge_segments.bin" \
  --input-meta "$ROOT/input/edge_segments.json" \
  --output "$ROOT/output"
