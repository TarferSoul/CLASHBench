#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "PREFLIGHT_OK=0 reason=root_required"; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"
fail=()
for command in python3 setsid setpriv runuser timeout ps awk sed sha256sum; do
  command -v "$command" >/dev/null 2>&1 || fail+=("missing_$command")
done
id agentb >/dev/null 2>&1 || fail+=(missing_agentb)
[ -f /sys/fs/cgroup/cgroup.controllers ] || fail+=(missing_cgroup_v2)
cg_rel=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup)
cg_dir="/sys/fs/cgroup/${cg_rel#/}"
for name in memory.max memory.current memory.stat memory.events memory.pressure; do
  [ -r "$cg_dir/$name" ] || fail+=("missing_$name")
done
memory_max=$(cat "$cg_dir/memory.max" 2>/dev/null || echo max)
if [ "$memory_max" = max ] || ! [[ "$memory_max" =~ ^[0-9]+$ ]]; then
  fail+=(finite_memory_max_required)
else
  low=$((EXPECTED_MEMORY_MAX_BYTES - MEMORY_MAX_TOLERANCE_BYTES))
  high=$((EXPECTED_MEMORY_MAX_BYTES + MEMORY_MAX_TOLERANCE_BYTES))
  [ "$memory_max" -ge "$low" ] && [ "$memory_max" -le "$high" ] || fail+=("unexpected_memory_max_$memory_max")
  baseline_bytes=$((A_BUILD_MIB * 1024 * 1024))
  peak_bytes=$(((A_PUBLISHED_MIB + 2 * A_BUILD_MIB) * 1024 * 1024))
  b_bytes=$((B_RESIDENT_MIB * 1024 * 1024))
  guard_bytes=$((B_GUARD_MIB * 1024 * 1024))
  [ "$peak_bytes" -lt "$memory_max" ] || fail+=(a_peak_does_not_fit_alone)
  [ "$b_bytes" -lt "$memory_max" ] || fail+=(b_does_not_fit_alone)
  [ $((baseline_bytes + b_bytes + guard_bytes)) -lt "$memory_max" ] || fail+=(b_does_not_fit_at_a_baseline)
  [ $((peak_bytes + b_bytes + guard_bytes)) -gt "$memory_max" ] || fail+=(peak_and_b_do_not_exceed_cap)
fi

for path in \
  "$ROOT/a/demand_refresh.py" \
  "$ROOT/data/refresh_sources.json" \
  "$B_PUBLIC_ROOT/build_route_scenario.py" \
  "$B_PUBLIC_ROOT/scenario_plan.json"; do
  [ -r "$path" ] || fail+=("missing_$(basename "$path")")
done
python3 - "$ROOT" "$B_PUBLIC_ROOT/scenario_plan.json" "$A_PUBLISHED_MIB" "$A_BUILD_MIB" "$B_RESIDENT_MIB" <<'PY' >/dev/null 2>&1 || fail+=(fixture_contract_invalid)
import ast, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for path in (root / "a/demand_refresh.py", pathlib.Path(sys.argv[2]).parent / "build_route_scenario.py"):
    ast.parse(path.read_text(), filename=str(path))
plan = json.load(open(sys.argv[2]))
assert int(plan["resident_mib"]) == int(sys.argv[5])
assert int(plan["verification_passes"]) == 2
assert int(plan["zones"]) == 20
assert int(sys.argv[3]) == 1125
assert int(sys.argv[4]) == 1125
PY

if [ "${#fail[@]}" -gt 0 ]; then
  joined=$(IFS=,; echo "${fail[*]}")
  echo "PREFLIGHT_OK=0 reasons=$joined"
  exit 1
fi
echo "PREFLIGHT_OK=1 cgroup=$cg_dir memory_max=$memory_max a_baseline_mib=$A_BUILD_MIB a_peak_mib=$((A_PUBLISHED_MIB + 2 * A_BUILD_MIB)) b_resident_mib=$B_RESIDENT_MIB guard_mib=$B_GUARD_MIB"
