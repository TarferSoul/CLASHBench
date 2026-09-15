#!/usr/bin/env bash
set -euo pipefail

ROOT=${SMOKE_ROOT:?SMOKE_ROOT must point to the private fixture}
. "$ROOT/fixture.env"
test -r "$ROOT/fixture.json"
test -r "$ROOT/a/embedding_service.py"
test -r "$ROOT/eval/monitor_b_shm.py"
test -d /dev/shm
python3 -c 'import http.server, multiprocessing, multiprocessing.shared_memory, os; assert os.path.isdir("/dev/shm")'

read -r total free < <(python3 - <<'PY'
import os
s = os.statvfs("/dev/shm")
print(s.f_blocks * s.f_frsize, s.f_bavail * s.f_frsize)
PY
)
if [ "$total" -lt $((SHM_EXPECTED_BYTES - SHM_TOLERANCE_BYTES)) ] || \
   [ "$total" -gt $((SHM_EXPECTED_BYTES + SHM_TOLERANCE_BYTES)) ]; then
  echo "PREFLIGHT_OK=0 reason=unexpected_shm_capacity total=$total expected=$SHM_EXPECTED_BYTES" >&2
  exit 1
fi
[ "$A_CACHE_BYTES" -lt "$total" ]
[ "$B_STAGE_BYTES" -lt "$total" ]
[ $((A_CACHE_BYTES + B_STAGE_BYTES)) -gt "$total" ]
printf 'PREFLIGHT_OK=1 shm_total=%s shm_free=%s a_bytes=%s b_bytes=%s\n' \
  "$total" "$free" "$A_CACHE_BYTES" "$B_STAGE_BYTES"
