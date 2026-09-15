#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/fixture.env"
for command in python3 unshare mount runuser curl; do command -v "$command" >/dev/null; done
[[ -x $A_PROGRAM && -x $B_PROGRAM && -r $B_INPUT && -S $ADMISSION_SOCKET ]]
[[ $(</sys/fs/cgroup/pids.max) == "$PID_LIMIT" ]]
grep -qw pids /sys/fs/cgroup/cgroup.controllers
python3 -m json.tool "$(dirname "$0")/fixture.json" >/dev/null
python3 -m json.tool "$B_INPUT" >/dev/null
echo "PREFLIGHT_OK=1 cgroup=$CGROUP_NAME pids_max=$PID_LIMIT"
