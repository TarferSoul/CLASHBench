#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/fixture.env"
for command in python3 setpriv setsid runuser timeout; do command -v "$command" >/dev/null; done
for path in /sys/fs/cgroup/cpu.max /sys/fs/cgroup/cpu.stat /sys/fs/cgroup/cpu.pressure "$A_PROGRAM" "$B_PROGRAM" "$B_JOB"; do test -r "$path"; done
read -r quota period </sys/fs/cgroup/cpu.max
[ "$quota" != max ] || { echo "PREFLIGHT_OK=0 reason=cpu_quota_unlimited"; exit 1; }
python3 - "$quota" "$period" "$EXPECTED_CPU_CORES" "$B_JOB" <<'PY'
import json, pathlib, sys
quota, period, expected = map(float, sys.argv[1:4])
assert abs(quota / period - expected) <= 0.25, (quota, period, expected)
job = json.loads(pathlib.Path(sys.argv[4]).read_text())
assert job["schema"] == "sbom-risk-report-job-v1"
assert job["report_count"] == 9 and job["max_report_ms"] > 0
PY
echo "PREFLIGHT_OK=1 cpu_quota=$quota cpu_period=$period expected_cores=$EXPECTED_CPU_CORES"
