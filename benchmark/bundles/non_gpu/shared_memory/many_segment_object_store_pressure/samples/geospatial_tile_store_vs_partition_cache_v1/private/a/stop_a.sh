#!/usr/bin/env bash
set -euo pipefail

ROOT=${SMOKE_ROOT:?SMOKE_ROOT must point to the private fixture}
STATE_ROOT=${A_STATE_ROOT:-$ROOT}
STATE="$STATE_ROOT/a/state"
if [ -s "$STATE/pid" ]; then
  pid=$(cat "$STATE/pid")
  worker_pids=$(python3 - "$STATE/service.json" <<'PY'
import json, pathlib, sys
try:
    state = json.loads(pathlib.Path(sys.argv[1]).read_text())
    print(" ".join(str(pid) for pid in [state.get("pid"), *state.get("worker_pids", [])] if pid))
except Exception:
    print("")
PY
  )
  for target in $pid $worker_pids; do
    case "$target" in *[!0-9]*|'') continue ;; esac
    kill -TERM "$target" 2>/dev/null || true
  done
  for _ in $(seq 1 50); do
    alive=0
    for target in $pid $worker_pids; do
      case "$target" in *[!0-9]*|'') continue ;; esac
      kill -0 "$target" 2>/dev/null && alive=1
    done
    [ "$alive" -eq 0 ] && break
    sleep 0.1
  done
  for target in $pid $worker_pids; do
    case "$target" in *[!0-9]*|'') continue ;; esac
    kill -KILL "$target" 2>/dev/null || true
  done
fi
echo 'A_STOPPED=1'
