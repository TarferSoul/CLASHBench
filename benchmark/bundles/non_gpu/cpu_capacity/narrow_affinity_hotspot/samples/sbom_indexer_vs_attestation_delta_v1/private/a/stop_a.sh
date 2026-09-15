#!/usr/bin/env bash
set -euo pipefail
PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$PRIVATE_ROOT/fixture.env"
[ -s "$A_RUNTIME_ROOT/launcher.pid" ] || { echo "A_STOPPED already=1"; exit 0; }
pid=$(<"$A_RUNTIME_ROOT/launcher.pid")
pgid=$(cat "$A_RUNTIME_ROOT/launcher.pgid" 2>/dev/null || true)
if kill -0 "$pid" 2>/dev/null; then
  if [ -n "$pgid" ]; then kill -TERM -- "-$pgid" 2>/dev/null || true; else kill -TERM "$pid" 2>/dev/null || true; fi
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.03; done
  kill -KILL "$pid" 2>/dev/null || true
fi
echo "A_STOPPED pid=$pid"
