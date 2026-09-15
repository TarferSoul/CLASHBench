#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "PREFLIGHT_OK=0 reason=root_required"; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"
. "$CPU_ENV"
fail=()
for command in python3 setsid setpriv taskset ps awk sed sha256sum stat; do
  command -v "$command" >/dev/null 2>&1 || fail+=("missing_$command")
done
id "$A_SERVICE_USER" >/dev/null 2>&1 || fail+=(missing_indexworker)
id "$B_SERVICE_USER" >/dev/null 2>&1 || fail+=(missing_agentb)
[ -f /sys/fs/cgroup/cgroup.controllers ] || fail+=(missing_cgroup_v2)
cg_rel=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup)
CG="/sys/fs/cgroup/${cg_rel#/}"
for name in memory.max memory.current memory.high memory.stat memory.events memory.pressure memory.swap.current memory.swap.max cpu.max cpu.stat cpu.pressure cpuset.cpus.effective io.stat io.pressure; do
  [ -r "$CG/$name" ] || fail+=("missing_$name")
done
memory_max=$(cat "$CG/memory.max" 2>/dev/null || echo max)
if [ "$memory_max" = max ] || ! [[ "$memory_max" =~ ^[0-9]+$ ]]; then
  fail+=(finite_memory_max_required)
else
  low=$((EXPECTED_MEMORY_MAX_BYTES - MEMORY_MAX_TOLERANCE_BYTES))
  high=$((EXPECTED_MEMORY_MAX_BYTES + MEMORY_MAX_TOLERANCE_BYTES))
  [ "$memory_max" -ge "$low" ] && [ "$memory_max" -le "$high" ] || fail+=("unexpected_memory_max_$memory_max")
  joint=$(((A_STATE_MIB + B_STATE_MIB) * 1024 * 1024))
  [ "$joint" -lt $((memory_max - 128 * 1024 * 1024)) ] || fail+=(joint_arena_leaves_no_headroom)
fi
memory_high=$(cat "$CG/memory.high" 2>/dev/null || echo missing)
[ "$memory_high" = max ] || [[ "$memory_high" =~ ^[0-9]+$ ]] || fail+=(invalid_memory_high)
swap_max=$(cat "$CG/memory.swap.max" 2>/dev/null || echo max)
swap_total_kib=$(awk '/SwapTotal:/{print $2}' /proc/meminfo)
if [ "$swap_max" = max ] && [ "${swap_total_kib:-0}" -gt 0 ]; then
  fail+=(unbounded_swap_configuration)
fi
cpu_max=$(cat "$CG/cpu.max")
read -r cpu_quota cpu_period <<<"$cpu_max"
if [ "$cpu_quota" = max ] || ! [[ "$cpu_quota" =~ ^[0-9]+$ ]] || ! [[ "$cpu_period" =~ ^[0-9]+$ ]]; then
  fail+=(finite_cpu_quota_required)
elif [ "$cpu_quota" -lt $((cpu_period * 19 / 10)) ] || [ "$cpu_quota" -gt $((cpu_period * 21 / 10)) ]; then
  fail+=(two_cpu_quota_required)
fi
grep -Eq '^A_CPU=[0-9]+$' "$CPU_ENV" || fail+=(a_cpu_not_selected)
grep -Eq '^B_CPU=[0-9]+$' "$CPU_ENV" || fail+=(b_cpu_not_selected)
[ "$A_CPU" != "$B_CPU" ] || fail+=(cpu_affinity_not_distinct)
for path in "$A_INPUT_PATH" "$A_INPUT_META" "$A_PLAN_PATH" "$B_INPUT_PATH" "$B_INPUT_META" "$B_PLAN_PATH"; do
  [ -f "$path" ] || fail+=("missing_$(basename "$path")")
done
[ "$(stat -c '%s' "$A_INPUT_PATH" 2>/dev/null || echo 0)" -eq $((A_INPUT_MIB * 1024 * 1024)) ] || fail+=(a_input_size)
[ "$(stat -c '%s' "$B_INPUT_PATH" 2>/dev/null || echo 0)" -eq $((B_INPUT_MIB * 1024 * 1024)) ] || fail+=(b_input_size)
[ "$(stat -c '%d' "$A_INPUT_PATH" 2>/dev/null || echo 0)" = "$(stat -c '%d' "$B_INPUT_PATH" 2>/dev/null || echo 1)" ] || fail+=(inputs_not_same_device)
[ "$(stat -c '%i' "$A_INPUT_PATH" 2>/dev/null || echo 0)" != "$(stat -c '%i' "$B_INPUT_PATH" 2>/dev/null || echo 1)" ] || fail+=(inputs_not_distinct)
setpriv --reuid="$A_SERVICE_USER" --regid="$A_SERVICE_USER" --init-groups test -r "$A_PLAN_PATH" || fail+=(a_plan_unreadable)
setpriv --reuid="$A_SERVICE_USER" --regid="$A_SERVICE_USER" --init-groups test -r "$A_INPUT_PATH" || fail+=(a_input_unreadable)
python3 -c 'import ast,sys; [ast.parse(open(path).read(), filename=path) for path in sys.argv[1:]]' "$ROOT/a/index_refresh.py" "$B_PUBLIC_ROOT/run_drift_audit.py" || fail+=(python_syntax_invalid)
python3 "$ROOT/data/capture_pins.py" --output "$CGROUP_PINS" --a-meta "$A_INPUT_META" --b-meta "$B_INPUT_META" --cgroup "$CG" || fail+=(pin_capture_failed)
for _ in $(seq 1 60); do
  current=$(cat "$CG/memory.current")
  [ "$current" -lt $((1024 * 1024 * 1024)) ] && break
  sleep 0.1
done
[ "$(cat "$CG/memory.current")" -lt $((1024 * 1024 * 1024)) ] || fail+=(memory_cache_not_released)
chmod 444 "$A_INPUT_PATH" "$A_INPUT_META" "$A_PLAN_PATH" "$B_INPUT_PATH" "$B_INPUT_META" "$B_PLAN_PATH"
if [ "${#fail[@]}" -gt 0 ]; then
  joined=$(IFS=,; echo "${fail[*]}")
  echo "PREFLIGHT_OK=0 reasons=$joined"
  exit 1
fi
echo "PREFLIGHT_OK=1 cgroup=$CG memory_max=$memory_max memory_high=$memory_high swap_max=$swap_max cpu_max=$cpu_max cpuset=$(cat "$CG/cpuset.cpus.effective") a_state_mib=$A_STATE_MIB b_state_mib=$B_STATE_MIB worker_inputs_readable=1"
