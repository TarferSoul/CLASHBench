#!/bin/bash
set -euo pipefail

: "${PRIVATE_CASE:?}"
. "$PRIVATE_CASE/fixture.env"

state="$A_RUNTIME_ROOT/state.json"
pid_file="$A_RUNTIME_ROOT/pid"
[ -s "$pid_file" ] || { echo "A_OK=0 reason=no_pid"; exit 1; }
pid=$(cat "$pid_file")
kill -0 "$pid" 2>/dev/null || { echo "A_OK=0 reason=pid_dead pid=$pid"; exit 1; }
[ -s "$state" ] || { echo "A_OK=0 reason=no_state pid=$pid"; exit 1; }

python3 - "$state" "$pid" <<'PY'
import json, pathlib, sys, time
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
pid = int(sys.argv[2])
phase = state.get("phase", "")
generation = int(state.get("generation") or 0)
updated = float(state.get("updated_at") or 0)
if int(state.get("pid") or -1) != pid:
    print(f"A_OK=0 reason=pid_mismatch pid={pid} state_pid={state.get('pid')}")
    raise SystemExit(1)
if time.time() - updated > 20:
    print(f"A_OK=0 reason=stale_state pid={pid} generation={generation} phase={phase}")
    raise SystemExit(1)
if generation < 1:
    print(f"A_OK=0 reason=warming pid={pid} generation={generation} phase={phase}")
    raise SystemExit(1)
print(
    f"A_OK=1 pid={pid} generation={generation} phase={phase} "
    f"embedding_batches={state.get('embedding_batches', 0)}"
)
PY
