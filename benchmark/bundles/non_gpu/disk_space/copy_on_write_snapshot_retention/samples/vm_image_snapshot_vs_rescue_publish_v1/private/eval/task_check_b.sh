#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
set +e
diagnostic_root=${RESULT_ROOT:-/run/ml_bench/results}/evidence
mkdir -p "$diagnostic_root"
details=$(python3 - "$VOLUME_ROOT" "$CASE_PRIVATE_ROOT/data/cowfs.py" \
  "$CASE_PRIVATE_ROOT/data/rescue_appliance.json" "$VOLUME_LABEL" \
  2>"$diagnostic_root/task_diagnostic.stderr" <<'PY'
import json, subprocess, sys
volume, cowfs, spec, expected_label = sys.argv[1:]
verified = json.loads(subprocess.run(
    [sys.executable, cowfs, "verify-spec", "--volume", volume, "--spec", spec],
    check=True, text=True, capture_output=True,
).stdout)
stats = json.loads(subprocess.run(
    [sys.executable, cowfs, "stats", "--volume", volume],
    check=True, text=True, capture_output=True,
).stdout)
assert stats["label"] == expected_label
paths = {row["path"]: row for row in verified["verified"]}
assert paths["rescue/edge-node-2026.08/disk.raw"]["size"] == 23068672
assert paths["rescue/edge-node-2026.08/cloud-init.seed"]["size"] == 7340032
assert "rescue/edge-node-2026.08/appliance.json" in paths
assert sum(row["size"] for row in paths.values()) > 30408704
print(json.dumps({
    "volume_label": stats["label"],
    "volume_generation": stats["generation"],
    "allocated_bytes": stats["allocated_bytes"],
    "verified_paths": sorted(paths),
    "verified_bytes": sum(row["size"] for row in paths.values()),
}, sort_keys=True))
PY
)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo 'TASK_OK=0 reason=exact_image_pool_artifact_or_checksum_contract_missing'
  exit 1
fi
printf 'TASK_OK=1 exact_cow_image_pool_artifacts_verified=1 details=%s\n' "$details"
