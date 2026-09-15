#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/fixture.env"

command -v python3 >/dev/null
command -v runuser >/dev/null

cgroup=/sys/fs/cgroup
if [ -r /proc/self/cgroup ]; then
  rel=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup | sed 's#^/##')
  if [ -n "$rel" ] && [ -d "/sys/fs/cgroup/$rel" ]; then
    cgroup="/sys/fs/cgroup/$rel"
  fi
fi

memory_max=$(cat "$cgroup/memory.max")
memory_current=$(cat "$cgroup/memory.current")
if [ "$memory_max" != "$MEMORY_MAX_BYTES" ]; then
  echo "PREFLIGHT_OK=0 reason=unexpected_memory_max expected=$MEMORY_MAX_BYTES actual=$memory_max cgroup=$cgroup"
  exit 1
fi

echo "PREFLIGHT_OK=1 cgroup=$cgroup memory_max=$memory_max memory_current=$memory_current a_state_mib=$A_STATE_MIB b_resident_mib=$B_RESIDENT_MIB guard_mib=$B_ADMISSION_GUARD_MIB"

