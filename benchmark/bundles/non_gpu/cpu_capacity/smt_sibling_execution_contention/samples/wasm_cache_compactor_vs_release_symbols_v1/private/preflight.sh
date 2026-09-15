#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "PREFLIGHT_OK=0 reason=root_required"; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"
fail=()
for command in python3 taskset setsid setpriv runuser ps awk sha256sum df stat; do
  command -v "$command" >/dev/null 2>&1 || fail+=("missing_$command")
done
id "$AGENT_USER" >/dev/null 2>&1 || fail+=(missing_agent_user)
[ -f /sys/fs/cgroup/cgroup.controllers ] || fail+=(missing_cgroup_v2)
[ "$(stat -f -c %T /dev/shm)" = tmpfs ] || fail+=(dev_shm_not_tmpfs)
[ -x "$A_PROGRAM" ] || fail+=(missing_a_program)
[ -x "$B_PROGRAM" ] || fail+=(missing_b_program)
[ -s "$B_JOB" ] || fail+=(missing_b_job)

cg_rel=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup)
cg_dir="/sys/fs/cgroup/${cg_rel#/}"
for name in cpu.max cpu.stat cpu.pressure io.pressure memory.current memory.max memory.events pids.current pids.max; do
  [ -r "$cg_dir/$name" ] || fail+=("missing_${name//./_}")
done
read -r quota period <"$cg_dir/cpu.max" || true
if ! [[ "${quota:-}" =~ ^[0-9]+$ && "${period:-}" =~ ^[0-9]+$ ]]; then
  fail+=(finite_measurable_cpu_limit_required)
else
  quota_ok=$(python3 - "$quota" "$period" <<'PY'
import sys
print(1 if int(sys.argv[1]) / int(sys.argv[2]) >= 3.0 else 0)
PY
)
  [ "$quota_ok" = 1 ] || fail+=(cpu_limit_has_insufficient_headroom)
fi

shm_available_mib=$(df -Pm /dev/shm | awk 'NR==2{print $4}')
[[ "$shm_available_mib" =~ ^[0-9]+$ ]] && [ "$shm_available_mib" -ge "$MIN_SHM_HEADROOM_MIB" ] || fail+=(insufficient_dev_shm_headroom)
memory_current=$(<"$cg_dir/memory.current")
memory_max=$(<"$cg_dir/memory.max")
if [[ "$memory_max" =~ ^[0-9]+$ ]]; then
  memory_headroom_mib=$(( (memory_max - memory_current) / 1024 / 1024 ))
  [ "$memory_headroom_mib" -ge "$MIN_MEMORY_HEADROOM_MIB" ] || fail+=(insufficient_memory_headroom)
else
  memory_headroom_mib=unlimited
fi
if [[ "$(<"$cg_dir/pids.max")" =~ ^[0-9]+$ ]]; then
  pids_headroom=$(( $(<"$cg_dir/pids.max") - $(<"$cg_dir/pids.current") ))
  [ "$pids_headroom" -ge 32 ] || fail+=(insufficient_pid_headroom)
fi

requested_pair_ordinal=$PAIR_ORDINAL
if ! python3 "$ROOT/topology_select.py" --ordinal "$requested_pair_ordinal" --policy "$PLACEMENT_POLICY_ID" --output "$TOPOLOGY_ENV"; then
  fail+=(unsupported_smt_topology_or_frequency_surface)
fi
if [ -s "$TOPOLOGY_ENV" ]; then
  . "$TOPOLOGY_ENV"
  [ "$A_CPU" != "$B_CPU" ] || fail+=(overlapping_logical_cpu_affinity)
  [ "$PAIR_ORDINAL" = "$requested_pair_ordinal" ] || fail+=(wrong_pair_ordinal)
  [ "$(cat "/sys/devices/system/cpu/cpu$A_CPU/topology/core_id")" = "$CORE_ID" ] || fail+=(a_core_changed)
  [ "$(cat "/sys/devices/system/cpu/cpu$B_CPU/topology/core_id")" = "$CORE_ID" ] || fail+=(b_core_changed)
  [ "$(cat "/sys/devices/system/cpu/cpu$A_CPU/topology/physical_package_id")" = "$PHYSICAL_PACKAGE_ID" ] || fail+=(a_package_changed)
  [ "$(cat "/sys/devices/system/cpu/cpu$B_CPU/topology/physical_package_id")" = "$PHYSICAL_PACKAGE_ID" ] || fail+=(b_package_changed)
  if [ "$THERMAL_MODE" = temperature ]; then
    IFS=, read -r -a thermal_files <<<"$THERMAL_PATHS"
    for thermal_file in "${thermal_files[@]}"; do
      [ -r "$thermal_file" ] || continue
      value=$(<"$thermal_file")
      [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -lt "$MAX_THERMAL_MILLIC" ] || fail+=(unstable_thermal_condition)
    done
  fi
fi

python3 "$ROOT/preflight_contract.py" "$B_JOB" "$A_INPUT_ROOT" "$B_INPUT_ROOT" >/dev/null 2>&1 || fail+=(fixture_contract_invalid)

if [ "${#fail[@]}" -gt 0 ]; then
  joined=$(IFS=,; echo "${fail[*]}")
  echo "PREFLIGHT_OK=0 reasons=$joined"
  exit 1
fi
quota_cores=$(python3 - "$quota" "$period" <<'PY'
import sys
print(f"{int(sys.argv[1]) / int(sys.argv[2]):.3f}")
PY
)
echo "PREFLIGHT_OK=1 pair_ordinal=$PAIR_ORDINAL A_CPU=$A_CPU B_CPU=$B_CPU MONITOR_CPU=$MONITOR_CPU package=$PHYSICAL_PACKAGE_ID core=$CORE_ID siblings=$THREAD_SIBLINGS_LIST affinity_disjoint=1 quota_cores=$quota_cores memory_headroom_mib=$memory_headroom_mib shm_headroom_mib=$shm_available_mib frequency_mode=$FREQUENCY_MODE thermal_mode=$THERMAL_MODE cache_topology=$CACHE_TOPOLOGY"
