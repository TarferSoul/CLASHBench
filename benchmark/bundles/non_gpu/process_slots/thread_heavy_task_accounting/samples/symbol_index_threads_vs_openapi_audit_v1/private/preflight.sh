#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
. "${CGROUP_ENV:?}"
[ "$(id -u)" -eq 0 ] || { echo "PREFLIGHT_OK=0 reason=root_required"; exit 1; }
for command in bash python3 findmnt setpriv timeout ps; do
  command -v "$command" >/dev/null || { echo "PREFLIGHT_OK=0 reason=missing_command command=$command"; exit 1; }
done
[ -d /sys/fs/cgroup ] && [ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] || { echo "PREFLIGHT_OK=0 reason=cgroup_v2_required"; exit 1; }
[ -r "$CGROUP_DIR/pids.current" ] && [ -r "$CGROUP_DIR/pids.events" ] && [ -r "$CGROUP_DIR/pids.max" ] || { echo "PREFLIGHT_OK=0 reason=pid_controller_not_readable"; exit 1; }
[ "$CGROUP_WRITE_MODE" = direct ] || [ "$CGROUP_WRITE_MODE" = userns ] || { echo "PREFLIGHT_OK=0 reason=unknown_pid_writer"; exit 1; }
[ "$(<"$CGROUP_DIR/pids.max")" = "$CGROUP_LIMIT" ] || { echo "PREFLIGHT_OK=0 reason=pid_limit_mismatch"; exit 1; }
id "$SERVICE_USER" >/dev/null
[ "$(id -u "$SERVICE_USER")" = "$SERVICE_UID" ]
[ -x "$A_TOOL" ] && [ -x "$B_TOOL" ]
[ "$(find "$A_SOURCE_ROOT" -maxdepth 1 -type f -name '*.json' | wc -l)" -eq "$A_SOURCE_COUNT" ]
[ "$(find "$B_SOURCE_ROOT" -maxdepth 1 -type f -name '*.json' | wc -l)" -eq "$B_DESCRIPTOR_COUNT" ]
python3 -m py_compile "$A_TOOL" "$B_TOOL" "$CASE_PRIVATE_ROOT/data/cgroup_snapshot.py"
echo "PREFLIGHT_OK=1 cgroup=$CGROUP_DIR pids_max=$CGROUP_LIMIT writer=$CGROUP_WRITE_MODE a_threads=$A_WORKER_THREADS b_workers=$B_WORKERS"
