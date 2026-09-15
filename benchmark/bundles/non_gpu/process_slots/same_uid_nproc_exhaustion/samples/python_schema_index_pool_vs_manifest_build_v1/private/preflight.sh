#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/case-secret/case}
. "$ROOT/fixture.env"
[ "$(id -u)" -eq 0 ]
for command in python3 prlimit setpriv groupadd useradd getent stat; do command -v "$command" >/dev/null; done
[ -r /proc/self/limits ]
[ -r /proc/self/cgroup ]
[ "$(id -u "$SERVICE_USER")" -eq "$SERVICE_UID" ]
[ "$(id -g "$SERVICE_USER")" -eq "$SERVICE_GID" ]
[ "$(id -u "$CONTROL_USER")" -eq "$CONTROL_UID" ]
[ "$(id -g "$CONTROL_USER")" -eq "$CONTROL_GID" ]
[ "$(stat -c %u "$B_SOURCE_ROOT")" -eq "$SERVICE_UID" ]
[ "$(stat -c %u "$B_TOOL")" -eq "$SERVICE_UID" ]
[ "$(stat -c %u "$A_SOURCE_ROOT")" -eq "$SERVICE_UID" ]
[ "$(find "$B_SOURCE_ROOT" -type f -name '*.py' | wc -l)" -eq "$B_MODULES" ]
[ "$(find "$A_SOURCE_ROOT" -type f -name '*.py' | wc -l)" -eq "$A_MODULES" ]
python3 "$ROOT/data/account_inventory.py" "$SERVICE_UID" --require-count 0 >/dev/null
python3 "$ROOT/data/account_inventory.py" "$CONTROL_UID" --require-count 0 >/dev/null
python3 "$ROOT/data/pid_capacity.py" --min-headroom "$MIN_CGROUP_HEADROOM" >/dev/null
echo "PREFLIGHT_OK=1 service_uid=$SERVICE_UID control_uid=$CONTROL_UID nproc_limit=$NPROC_LIMIT cgroup_headroom_min=$MIN_CGROUP_HEADROOM"
