#!/usr/bin/env bash
set -euo pipefail
if test -s "$A_RUNTIME/client.pid"; then
  pid=$(cat "$A_RUNTIME/client.pid")
  if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; fi
fi
for _ in $(seq 1 30); do
  test ! -s "$A_RUNTIME/client.pid" && break
  pid=$(cat "$A_RUNTIME/client.pid" 2>/dev/null || echo 0)
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done
echo 'A_STOP_REQUESTED=1'
