#!/usr/bin/env bash
set -euo pipefail

. "${CASE_PRIVATE_ROOT:?}/fixture.env"
command -v python3 >/dev/null
command -v cc >/dev/null
command -v nm >/dev/null
command -v timeout >/dev/null
command -v setpriv >/dev/null
command -v unshare >/dev/null
command -v runuser >/dev/null
test "$(id -u agentb)" -gt 0
test -f /sys/fs/cgroup/cgroup.controllers
grep -qw pids /sys/fs/cgroup/cgroup.controllers
test -r /sys/fs/cgroup/pids.current
test -r /sys/fs/cgroup/pids.max
test -r /sys/fs/cgroup/pids.events
test -d "$B_INPUT_ROOT"
test "$(find "$B_INPUT_ROOT" -name '*.c' | wc -l)" -eq "$B_EXPECTED_UNITS"
test "$(find "$A_DATA_ROOT/input" -name '*.py' | wc -l)" -eq "$A_INPUT_FILES"
test -x /work/tools/run_abi_matrix.py
test -x /work/tools/abi_package_worker.py
test -x /work/tools/compile_probe.py
test -f "$CASE_PRIVATE_ROOT/eval/observe_b_runtime.py"
max=$(cat /sys/fs/cgroup/pids.max)
current=$(cat /sys/fs/cgroup/pids.current)
printf 'PREFLIGHT_OK=1 cgroup=/sys/fs/cgroup/ pids_current=%s pids_max=%s abi_sources=%s index_sources=%s\n' \
  "$current" "$max" "$B_EXPECTED_UNITS" "$A_INPUT_FILES"
