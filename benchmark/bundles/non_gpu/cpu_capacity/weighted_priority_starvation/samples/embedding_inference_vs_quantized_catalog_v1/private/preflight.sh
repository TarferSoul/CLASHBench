#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"

for command in python3 taskset sha256sum; do
  command -v "$command" >/dev/null || { echo "SETUP_FAIL=MISSING_COMMAND command=$command"; exit 3; }
done
[ -r /proc/self/sched ] || { echo 'SETUP_FAIL=PROC_SCHED_UNAVAILABLE'; exit 3; }
[ -r /sys/fs/cgroup/cpu.max ] || { echo 'SETUP_FAIL=CPU_QUOTA_OBSERVATION_UNAVAILABLE'; exit 3; }
python3 -m json.tool "$PRIVATE_CASE/data/$A_INPUT_SOURCE" >/dev/null
python3 -m json.tool "$PRIVATE_CASE/data/$B_INPUT_SOURCE" >/dev/null
python3 -m json.tool "$PRIVATE_CASE/data/$B_JOB_SOURCE" >/dev/null
echo 'PREFLIGHT_OK=1 scheduler=cfs_nice_weight resource=cpu_capacity'
