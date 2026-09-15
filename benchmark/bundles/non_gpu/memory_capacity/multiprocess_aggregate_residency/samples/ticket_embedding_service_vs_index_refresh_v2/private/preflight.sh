#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"

rm -rf /work
install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 755 /work "$B_PUBLIC_ROOT" "$B_OUTPUT_ROOT"
cp -a "$ROOT/workload/." "$B_PUBLIC_ROOT/"
chown -R "$SERVICE_UID:$SERVICE_GID" "$B_PUBLIC_ROOT"

runuser -u "$SERVICE_USER" -- env -i HOME="/home/$SERVICE_USER" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  python3 "$B_PUBLIC_ROOT/make_ticket_fixture.py" --root "$B_PUBLIC_ROOT" --job "$B_JOB_PATH" \
  --resident-mib "$B_WORKER_RESIDENT_MIB" --guard-mib "$B_ADMISSION_GUARD_MIB" >/tmp/ticket_fixture_init.txt

missing=()
for command in bash python3 runuser setpriv timeout ps sha256sum getent groupadd useradd; do
  command -v "$command" >/dev/null 2>&1 || missing+=("$command")
done
[ "${#missing[@]}" = 0 ] || { echo "SETUP_FAIL=MISSING_COMMANDS ${missing[*]}" >&2; exit 1; }

[ -f /sys/fs/cgroup/cgroup.controllers ] || { echo "SETUP_FAIL=CGROUP_V2_REQUIRED" >&2; exit 1; }
for name in memory.max memory.current memory.stat memory.events; do
  [ -r "/sys/fs/cgroup/$name" ] || { echo "SETUP_FAIL=CGROUP_MEMORY_FILE_UNREADABLE name=$name" >&2; exit 1; }
done

python3 - "$ROOT/fixture.json" "$EXPECTED_MEMORY_MAX_BYTES" "$MEMORY_MAX_TOLERANCE_BYTES" "$B_PUBLIC_ROOT/build_ticket_index.py" "$B_PUBLIC_ROOT/verify_index.py" "$B_JOB_PATH" <<'PY'
import json
import pathlib
import sys

fixture, expected, tolerance, builder, verifier, job = sys.argv[1:]
json.loads(pathlib.Path(fixture).read_text())
memory_text = pathlib.Path("/sys/fs/cgroup/memory.max").read_text().strip()
if memory_text == "max":
    raise SystemExit("SETUP_FAIL=FINITE_MEMORY_MAX_REQUIRED")
memory_max = int(memory_text)
expected = int(expected)
tolerance = int(tolerance)
if abs(memory_max - expected) > tolerance:
    raise SystemExit(f"SETUP_FAIL=MEMORY_MAX_MISMATCH actual={memory_max} expected={expected} tolerance={tolerance}")
for path in (builder, verifier, job):
    if not pathlib.Path(path).exists():
        raise SystemExit(f"SETUP_FAIL=PUBLIC_WORKLOAD_MISSING path={path}")
job_data = json.loads(pathlib.Path(job).read_text())
if job_data.get("required_worker_count") != 4 or len(job_data.get("shards", [])) != 4:
    raise SystemExit("SETUP_FAIL=JOB_WORKER_OR_SHARD_COUNT")
print(f"PREFLIGHT_OK=1 memory_max={memory_max} builder={builder} job={job}")
PY
