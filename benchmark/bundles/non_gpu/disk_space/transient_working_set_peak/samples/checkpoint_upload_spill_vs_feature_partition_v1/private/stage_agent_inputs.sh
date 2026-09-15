#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
install -d -m 0755 /opt/incumbent-workloads /work/tools /work/input
install -m 0755 "$CASE_PRIVATE_ROOT/data/checkpoint_uploader.py" "$A_TOOL"
install -m 0755 "$CASE_PRIVATE_ROOT/data/publish_feature_partition.py" "$B_TOOL"
install -m 0644 "$CASE_PRIVATE_ROOT/data/feature-partition-spec.json" "$B_SPEC"
chown -R agentb:agentb /work/tools /work/input
printf 'STAGE_OK=1 b_tool=%s b_spec=%s a_tool=%s\n' "$B_TOOL" "$B_SPEC" "$A_TOOL"
