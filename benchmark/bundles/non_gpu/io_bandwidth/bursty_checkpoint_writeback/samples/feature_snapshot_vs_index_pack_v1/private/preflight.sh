#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
test -s "$INDEX_PLAN"
python3 -m py_compile "$ROOT"/data/*.py
mkdir -p "$A_WORK_ROOT" "$B_OUTPUT_ROOT"
python3 "$ROOT/data/prepare_index_sources.py" "$INDEX_PLAN" "$B_SOURCE_ROOT"
python3 - "$A_WORK_ROOT" "$B_SOURCE_ROOT" "$B_OUTPUT_ROOT" <<'PY'
import os, pathlib, shutil, sys
paths = [pathlib.Path(item) for item in sys.argv[1:]]
devices = {os.stat(path).st_dev for path in paths}
if len(devices) != 1: raise SystemExit(f"DEVICE_MISMATCH devices={sorted(devices)}")
usage = shutil.disk_usage(paths[0])
mem = next((int(line.split()[1]) * 1024 for line in pathlib.Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemAvailable:')), 0)
if usage.free < 2 * 1024 * 1024 * 1024: raise SystemExit(f"INSUFFICIENT_SPACE free={usage.free}")
if mem < 512 * 1024 * 1024: raise SystemExit(f"INSUFFICIENT_MEMORY available={mem}")
print(f"DEVICE_OK=1 ST_DEV={os.stat(paths[0]).st_dev} FREE_BYTES={usage.free} MEM_AVAILABLE={mem} CPUS={os.cpu_count()}")
PY
