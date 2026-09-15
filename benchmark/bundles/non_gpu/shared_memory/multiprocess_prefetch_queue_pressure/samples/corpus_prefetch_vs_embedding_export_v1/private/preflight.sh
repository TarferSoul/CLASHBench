#!/usr/bin/env bash
set -euo pipefail

ROOT=${PREFETCH_ROOT:?PREFETCH_ROOT must point to the private fixture}
. "$ROOT/fixture.env"
python3 - <<'PY'
from multiprocessing import shared_memory
import os
import sys

assert sys.version_info >= (3, 9)
info = os.statvfs('/dev/shm')
total = info.f_blocks * info.f_frsize
assert total >= 32 * 1024 * 1024, f'/dev/shm too small: {total}'
probe = shared_memory.SharedMemory(create=True, size=4096)
probe.buf[:] = b'x' * 4096
probe.close()
probe.unlink()
print(f'PREFLIGHT_OK=1 shm_bytes={total}')
PY
test -s "$ROOT/data/training_corpus.jsonl"
test -s "$ROOT/data/code_search_corpus.jsonl"
test -x "$ROOT/data/run_embedding_export.py"

