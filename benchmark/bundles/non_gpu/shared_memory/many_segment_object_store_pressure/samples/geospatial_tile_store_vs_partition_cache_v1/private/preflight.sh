#!/usr/bin/env bash
set -euo pipefail

ROOT=${SMOKE_ROOT:?SMOKE_ROOT must point to the private fixture}
test -r "$ROOT/fixture.env"
test -r "$ROOT/data/tile_features.csv"
python3 -c 'import multiprocessing.shared_memory, http.server, csv, os; assert os.path.isdir("/dev/shm")'
mount_line=$(df -P /dev/shm | tail -n 1)
printf 'PREFLIGHT_OK=1 shm=%s\n' "$mount_line"

