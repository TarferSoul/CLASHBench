#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
mkdir -p /work/tools /work/ops
install -m 0755 "$CASE_PRIVATE_ROOT/data/build_calibration_pack.py" "$B_TOOL"
install -m 0755 "$CASE_PRIVATE_ROOT/data/checkpoint_export_worker.py" "$INCUMBENT_TOOL"
install -m 0644 "$CASE_PRIVATE_ROOT/data/calibration-pack-spec.json" "$B_SPEC"
chown -R agentb:agentb /work/tools /work/ops "$B_SPEC"
printf 'STAGE_OK=1 builder=%s spec=%s incumbent_tool=%s\n' "$B_TOOL" "$B_SPEC" "$INCUMBENT_TOOL"

