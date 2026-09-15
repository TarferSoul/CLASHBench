#!/usr/bin/env bash
set -euo pipefail

ROOT=${PREFETCH_ROOT:?PREFETCH_ROOT must point to the private fixture}
. "$ROOT/fixture.env"
STATE_DIR=${A_STATE_DIR:-/var/lib/corpus-prefetch}
PID_FILE="$STATE_DIR/supervisor.pid"
STATE_FILE="$STATE_DIR/state.json"

test -s "$PID_FILE"
pid=$(cat "$PID_FILE")
kill -0 "$pid" 2>/dev/null
python3 - "$STATE_FILE" "$pid" "$A_WORKERS" <<'PY'
import json
import os
from pathlib import Path
import sys

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
pid = int(sys.argv[2])
workers = int(sys.argv[3])
assert state["ready"] == 1
assert state["pid"] == pid
assert len(state["worker_pids"]) == workers
assert state["progress_batches"] >= workers * state["recipe"]["prefetch_factor"]
assert state["allocated_bytes"] >= int(state["recipe"]["target_tensor_bytes"] * 0.90)
assert state["names_unlinked"] is True
for process_id in [pid, *state["worker_pids"]]:
    os.kill(process_id, 0)
assert Path(state["output_file"]).is_file()
print(
    f'A_HEALTHY=1 pid={pid} workers={workers} progress={state["progress_batches"]} '
    f'allocated={state["allocated_bytes"]} recipe={state["recipe_hash"]}'
)
PY

