#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/fixture.env"
for command in python3 unshare mount setpriv curl findmnt; do command -v "$command" >/dev/null; done
[[ -x $A_PROGRAM && -x $B_PROGRAM && -r $B_INPUT ]]
[[ -r /proc/self/cgroup && -r $CGROUP_PARENT/pids.max && -r $CGROUP_A/cgroup.procs && -r $CGROUP_B/cgroup.procs ]]
[[ $(<"$CGROUP_PARENT/pids.max") == "$PID_LIMIT" ]]
python3 -m json.tool "$(dirname "$0")/fixture.json" >/dev/null
python3 -m json.tool "$B_INPUT" >/dev/null
echo "PREFLIGHT_OK=1 ancestor=$CGROUP_PARENT_NAME pids_max=$PID_LIMIT a_leaf=$CGROUP_A_NAME b_leaf=$CGROUP_B_NAME"
