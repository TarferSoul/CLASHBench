#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
bash "$ROOT/a/stop_sender.sh" >/dev/null 2>&1 || true
for name in receiver server; do
  if [ -s "$A_RUNTIME_ROOT/$name.pid" ]; then
    pid=$(cat "$A_RUNTIME_ROOT/$name.pid"); kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true; fi
  fi
  rm -f "$A_RUNTIME_ROOT/$name.pid" "$A_RUNTIME_ROOT/$name.starttime" "$A_RUNTIME_ROOT/$name.pgid"
done
bash "$ROOT/a/setup_link.sh" down >/dev/null 2>&1 || true
echo "A_STOPPED=1"
