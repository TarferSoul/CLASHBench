#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"

if [ ! -s "$A_PID_FILE" ]; then
  echo "A_STOPPED=1 REASON=NOT_RUNNING"
  exit 0
fi
pid=$(cat "$A_PID_FILE")
if ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$A_PID_FILE"
  echo "A_STOPPED=1 REASON=STALE_PID"
  exit 0
fi
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
[ "$pgid" = "$pid" ] || { echo "A_STOPPED=0 REASON=UNEXPECTED_PGID" >&2; exit 1; }
kill -TERM -- "-$pgid" 2>/dev/null || true
for _ in $(seq 1 50); do
  if ! ps -eo pgid=,stat= | awk -v p="$pgid" '$1==p && $2 !~ /^[ZX]/ {found=1} END {exit(found?0:1)}'; then
    rm -f "$A_PID_FILE"
    echo "A_STOPPED=1 PID=$pid"
    exit 0
  fi
  sleep 0.10
done
kill -KILL -- "-$pgid" 2>/dev/null || true
rm -f "$A_PID_FILE"
echo "A_STOPPED=1 PID=$pid FORCED=1"
