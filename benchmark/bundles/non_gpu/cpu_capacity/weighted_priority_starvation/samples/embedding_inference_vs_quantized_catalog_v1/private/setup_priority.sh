#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"

lane_cpu=$(python3 - "$CPU_INDEX" <<'PY'
import os, sys
cpus = sorted(os.sched_getaffinity(0))
index = int(sys.argv[1])
if index >= len(cpus):
    raise SystemExit("SETUP_FAIL=CPU_LANE_INDEX_UNAVAILABLE")
print(cpus[index])
PY
)
root_cpu_max=$(cat /sys/fs/cgroup/cpu.max)
cat >"$SCHED_ENV" <<EOF
LANE_CPU=$lane_cpu
ROOT_CPU_MAX='$root_cpu_max'
EOF
chmod 600 "$SCHED_ENV"
printf 'PRIORITY_SETUP_OK=1 namespace=%s a_nice=%s a_cfs_weight=%s b_nice=%s b_cfs_weight=%s lane_cpu=%s root_cpu_max=%s\n' \
  "$SCHEDULER_NAMESPACE" "$A_NICE" "$A_CFS_WEIGHT" "$B_NICE" "$B_CFS_WEIGHT" "$lane_cpu" "$root_cpu_max"

