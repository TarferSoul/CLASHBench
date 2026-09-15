#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
pid=$(cat "$COLLECTOR_RUNTIME/collector.pid" 2>/dev/null || true)
if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
  echo "COLLECTOR_NOT_RUNNING"
  exit 0
fi
kill -TERM "$pid"
for _ in $(seq 1 80); do
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  if [ -z "$state" ] || [ "$state" = Z ]; then
    echo "COLLECTOR_STOPPED_NORMAL pid=$pid"
    exit 0
  fi
  sleep 0.05
done
kill -KILL "$pid" 2>/dev/null || true
echo "COLLECTOR_STOPPED_FORCED pid=$pid"
exit 1
