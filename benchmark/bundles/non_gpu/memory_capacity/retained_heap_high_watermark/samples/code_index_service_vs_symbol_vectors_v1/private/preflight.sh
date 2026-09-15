#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"

[ "$(id -u)" = 0 ] || { echo "PREFLIGHT_OK=0 reason=root_required"; exit 1; }
command -v python3 >/dev/null || { echo "PREFLIGHT_OK=0 reason=python3_missing"; exit 1; }
command -v runuser >/dev/null || { echo "PREFLIGHT_OK=0 reason=runuser_missing"; exit 1; }
[ -r /proc/self/cgroup ] || { echo "PREFLIGHT_OK=0 reason=proc_cgroup_missing"; exit 1; }
cg_rel=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup)
CG="/sys/fs/cgroup/${cg_rel#/}"
[ -r "$CG/memory.max" ] || { echo "PREFLIGHT_OK=0 reason=memory_max_missing"; exit 1; }
[ -r "$CG/memory.current" ] || { echo "PREFLIGHT_OK=0 reason=memory_current_missing"; exit 1; }
memory_max=$(cat "$CG/memory.max")
[ "$memory_max" != max ] || { echo "PREFLIGHT_OK=0 reason=finite_memory_max_required"; exit 1; }
python3 -m py_compile "$A_PROGRAM" "$B_PROGRAM"
python3 - "$A_DATA" "$B_PLAN" <<'PY'
import json, sys
fixture = json.load(open(sys.argv[1]))
plan = json.load(open(sys.argv[2]))
assert fixture["canary_symbol"] in {symbol for module in fixture["modules"] for symbol in module["symbols"]}
assert int(plan["resident_mib"]) >= 1000
assert int(plan["partition_count"]) == 16
assert len(plan["symbols"]) == 64
PY
echo "PREFLIGHT_OK=1 memory_max=$memory_max a_cache_mib=$A_CACHE_MIB b_resident_mib=$B_RESIDENT_MIB"

