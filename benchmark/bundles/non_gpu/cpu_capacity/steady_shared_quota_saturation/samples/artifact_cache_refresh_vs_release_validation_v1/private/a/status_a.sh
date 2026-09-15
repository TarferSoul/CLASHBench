#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
python3 - "$A_STATE_ROOT/service.json" "$A_WORKERS" <<'PY'
import json, pathlib, sys, time
path, expected = pathlib.Path(sys.argv[1]), int(sys.argv[2])
first = json.loads(path.read_text())
if first.get("workers") != expected or len(first.get("worker_pids", [])) != expected:
    raise SystemExit(1)
for pid in [first["supervisor_pid"], *first["worker_pids"]]:
    if pathlib.Path(f"/proc/{pid}/stat").read_text().split()[2] in {"T", "t", "Z", "X"}:
        raise SystemExit(1)
before = (first.get("compile_cycles", 0), first.get("compiled_modules", 0), first.get("cache_blocks", 0))
time.sleep(0.25)
second = json.loads(path.read_text())
after = (second.get("compile_cycles", 0), second.get("compiled_modules", 0), second.get("cache_blocks", 0))
if after[0] <= before[0] or after[1] <= before[1] or time.time_ns() - second["updated_ns"] > 2_000_000_000:
    raise SystemExit(1)
print(f"A_HEALTHY=1 supervisor_pid={second['supervisor_pid']} workers={expected} cycles={after[0]} compiled_modules={after[1]} cache_blocks={after[2]}")
PY
