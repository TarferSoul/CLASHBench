#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

[ "$(id -u)" -eq 0 ]
for command in python3 setpriv stat df groupadd useradd; do
  command -v "$command" >/dev/null
done
mountpoint -q /dev/shm
python3 - <<'PY'
import os
import sys

stat = os.statvfs("/dev/shm")
free = stat.f_bavail * stat.f_frsize
assert free >= 32 * 1024 * 1024, f"/dev/shm too small: {free}"
assert hasattr(os, "posix_fallocate"), "python lacks posix_fallocate"
print(f"PREFLIGHT_OK=1 shm_free_bytes={free} python={sys.version_info.major}.{sys.version_info.minor}")
PY
