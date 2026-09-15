#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CPU=$(cat "$ROOT/cpu_id.txt")
exec taskset -c "$CPU" python3 "$ROOT/run_drift_audit.py" \
  --plan "$ROOT/analysis_plan.json" \
  --input "$ROOT/input/validation_vectors.bin" \
  --input-meta "$ROOT/input/validation_vectors.json" \
  --output "$ROOT/output"
