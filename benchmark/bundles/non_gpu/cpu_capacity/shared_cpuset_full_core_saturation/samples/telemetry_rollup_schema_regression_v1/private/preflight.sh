#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/fixture.env"
. "$CPU_ENV"

[ "$(id -u)" -eq 0 ] || { echo "SETUP_FAIL=ROOT_REQUIRED" >&2; exit 1; }
for command in bash python3 taskset setpriv runuser ps sha256sum; do
  command -v "$command" >/dev/null || { echo "SETUP_FAIL=MISSING_COMMAND COMMAND=$command" >&2; exit 1; }
done
python3 - "$RESULT_ROOT/evidence/cpu_topology.json" "$CPU_COUNT" "$QUOTA_HEADROOM_RATIO_MIN" "$B_INPUT" "$B_JOB" <<'PY'
import json, pathlib, sys
topology_path, count, headroom_min, input_path, job_path = sys.argv[1:]
topology = json.loads(pathlib.Path(topology_path).read_text())
job = json.loads(pathlib.Path(job_path).read_text())
selected = topology.get("selected_cpus", [])
if len(selected) != int(count) or not topology.get("selected_are_distinct_physical_cores") or topology.get("selected_include_smt_siblings"):
    raise SystemExit("SETUP_FAIL=INVALID_PHYSICAL_CORE_LANE")
headroom = topology.get("quota_headroom_over_lane")
if headroom is not None and float(headroom) < float(headroom_min):
    raise SystemExit(f"SETUP_FAIL=BINDING_CPU_QUOTA HEADROOM={headroom}")
if job.get("cpus") != selected or job.get("workers") != len(selected):
    raise SystemExit("SETUP_FAIL=JOB_LANE_MISMATCH")
source = json.loads(pathlib.Path(input_path).read_text())
if source.get("schema") != "schema-case-set-v1" or len(source.get("cases", [])) < 4:
    raise SystemExit("SETUP_FAIL=INVALID_SCHEMA_CASE_FIXTURE")
print(f"PREFLIGHT_OK=1 CPU_LIST={','.join(map(str, selected))} QUOTA_HEADROOM={headroom if headroom is not None else 'unlimited'}")
PY
