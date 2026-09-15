#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
# shellcheck disable=SC1091
. "$ROOT/data/quota_lib.sh"
python3 "$ROOT/data/export_onnx_bundle.py" verify --spec "$ROOT/data/deployment_spec.json" \
  --out "$B_OUTPUT" --mount "$QUOTA_ROOT" --uid "$(id -u "$AGENT_USER")"
