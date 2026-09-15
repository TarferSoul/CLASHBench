#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/fixture.env"

[ "$(id -u)" -eq 0 ] || { echo "SETUP_FAIL=ROOT_REQUIRED" >&2; exit 1; }
for command in bash python3 runuser ps sha256sum; do
  command -v "$command" >/dev/null || { echo "SETUP_FAIL=MISSING_COMMAND command=$command" >&2; exit 1; }
done
for path in /sys/fs/cgroup/cpu.max /sys/fs/cgroup/cpu.stat /sys/fs/cgroup/cpu.pressure \
  /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.events \
  /sys/fs/cgroup/pids.current /sys/fs/cgroup/pids.max; do
  [ -r "$path" ] || { echo "SETUP_FAIL=CGROUP_FILE_UNREADABLE path=$path" >&2; exit 1; }
done

python3 - "$EXPECTED_QUOTA_CORES" "$QUOTA_TOLERANCE_CORES" "$(dirname "$0")/fixture.json" "$B_INPUT_PATH" <<'PY'
import hashlib, json, pathlib, sys
expected, tolerance, fixture_path, input_path = float(sys.argv[1]), float(sys.argv[2]), pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4])
quota, period = pathlib.Path("/sys/fs/cgroup/cpu.max").read_text().split()
if quota == "max":
    raise SystemExit("SETUP_FAIL=FINITE_CPU_MAX_REQUIRED")
cores = int(quota) / int(period)
if abs(cores - expected) > tolerance:
    raise SystemExit(f"SETUP_FAIL=CPU_QUOTA_MISMATCH expected={expected} actual={cores}")
stat = dict(line.split() for line in pathlib.Path("/sys/fs/cgroup/cpu.stat").read_text().splitlines() if len(line.split()) == 2)
for key in ("usage_usec", "nr_periods", "nr_throttled"):
    if key not in stat:
        raise SystemExit(f"SETUP_FAIL=CPU_STAT_KEY_MISSING key={key}")
if "throttled_usec" not in stat and "throttled_time" not in stat:
    raise SystemExit("SETUP_FAIL=CPU_STAT_THROTTLE_TIME_MISSING")
fixture = json.loads(fixture_path.read_text())
source = json.loads(input_path.read_text())
if fixture["resource"]["profile_id"] != "steady_shared_quota_saturation":
    raise SystemExit("SETUP_FAIL=PROFILE_MISMATCH")
if source.get("schema") != "retrieval-relevance-cases-v1" or len(source.get("queries", [])) != 12:
    raise SystemExit("SETUP_FAIL=INPUT_SCHEMA")
print(f"PREFLIGHT_OK=1 CPU_MAX={quota}/{period} QUOTA_CORES={cores:.3f} INPUT_SHA256={hashlib.sha256(input_path.read_bytes()).hexdigest()}")
PY
