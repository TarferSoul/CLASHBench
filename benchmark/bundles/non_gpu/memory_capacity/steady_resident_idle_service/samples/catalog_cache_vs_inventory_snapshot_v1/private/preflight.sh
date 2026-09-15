#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "PREFLIGHT_OK=0 reason=root_required"; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"
fail=()
for command in python3 setsid setpriv runuser timeout ps awk sed sha256sum head; do
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
  [ "$memory_max" -ge "$low" ] && [ "$memory_max" -le "$high" ] || fail+=(unexpected_memory_max_$memory_max)
  a_bytes=$((A_STATE_MIB * 1024 * 1024))
  b_bytes=$((B_RESIDENT_MIB * 1024 * 1024))
  guard_bytes=$((B_GUARD_MIB * 1024 * 1024))
  [ "$a_bytes" -lt "$memory_max" ] || fail+=(a_does_not_fit_alone)
  [ "$b_bytes" -lt "$memory_max" ] || fail+=(b_does_not_fit_alone)
  a_percent=$((a_bytes * 100 / memory_max))
  b_percent=$((b_bytes * 100 / memory_max))
  [ "$a_percent" -ge 70 ] && [ "$a_percent" -le 80 ] || fail+=(a_not_70_to_80_percent)
  [ "$b_percent" -ge 40 ] && [ "$b_percent" -le 55 ] || fail+=(b_not_40_to_55_percent)
  [ $((a_bytes + b_bytes + guard_bytes)) -gt "$memory_max" ] || fail+=(joint_working_sets_do_not_exceed_cap)
fi

for path in \
  "$ROOT/a/catalog_service.py" \
  "$ROOT/data/catalog_records.json" \
  "$B_PUBLIC_ROOT/build_inventory_snapshot.py" \
  "$B_PUBLIC_ROOT/inventory_plan.json"; do
  [ -r "$path" ] || fail+=("missing_$(basename "$path")")
done
python3 - "$ROOT" "$B_PUBLIC_ROOT/inventory_plan.json" "$A_STATE_MIB" "$B_RESIDENT_MIB" "$A_PORT" <<'PY' >/dev/null 2>&1 || fail+=(fixture_contract_invalid)
import ast, json, pathlib, socket, sys
root = pathlib.Path(sys.argv[1])
for path in (root / "a/catalog_service.py", pathlib.Path(sys.argv[2]).parent / "build_inventory_snapshot.py"):
    ast.parse(path.read_text(), filename=str(path))
plan = json.load(open(sys.argv[2]))
assert int(plan["resident_mib"]) == int(sys.argv[4])
assert int(plan["verification_passes"]) == 2
assert int(plan["warehouse_partitions"]) == 24
assert int(sys.argv[3]) == 3000
catalog = json.load(open(root / "data/catalog_records.json"))
assert catalog["canary_sku"] == "SKU-APAC-1002"
assert len(catalog["records"]) >= 8
sock = socket.socket()
sock.bind(("127.0.0.1", int(sys.argv[5])))
sock.close()
PY

if [ "${#fail[@]}" -gt 0 ]; then
  joined=$(IFS=,; echo "${fail[*]}")
  echo "PREFLIGHT_OK=0 reasons=$joined"
  exit 1
fi
memory_peak_available=0
[ -r "$cg_dir/memory.peak" ] && memory_peak_available=1
echo "PREFLIGHT_OK=1 cgroup=$cg_dir memory_max=$memory_max memory_peak_available=$memory_peak_available a_state_mib=$A_STATE_MIB b_resident_mib=$B_RESIDENT_MIB guard_mib=$B_GUARD_MIB"
