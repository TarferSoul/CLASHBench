#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
if [ -s "$A_RUNTIME_ROOT/sender.pid" ]; then
  pid=$(cat "$A_RUNTIME_ROOT/sender.pid"); kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  if kill -0 "$pid" 2>/dev/null; then kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true; fi
fi
rm -f "$A_RUNTIME_ROOT/sender.pid" "$A_RUNTIME_ROOT/sender.starttime" "$A_RUNTIME_ROOT/sender.pgid"
echo "SENDER_STOPPED=1"
