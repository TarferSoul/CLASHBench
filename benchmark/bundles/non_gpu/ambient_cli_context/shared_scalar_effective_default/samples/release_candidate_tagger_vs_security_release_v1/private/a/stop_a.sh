#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$PRIVATE_ROOT/fixture.env"
pid=$(cat "$A_STATE/tagger.pid" 2>/dev/null || true)

if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
  echo 'STOP_A_OK=1 state=not_recorded'
  exit 0
fi
if ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$A_STATE/tagger.pid"
  echo "STOP_A_OK=1 state=already_stopped pid=$pid"
  exit 0
fi

pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
kill -TERM -- "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
for _ in $(seq 1 40); do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$A_STATE/tagger.pid"
    echo "STOP_A_OK=1 state=terminated pid=$pid pgid=$pgid"
    exit 0
  fi
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  if [ "$state" = Z ]; then
    rm -f "$A_STATE/tagger.pid"
    echo "STOP_A_OK=1 state=zombie_after_termination pid=$pid pgid=$pgid"
    exit 0
  fi
  sleep 0.05
done
kill -KILL -- "-$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
rm -f "$A_STATE/tagger.pid"
echo "STOP_A_OK=1 state=killed_after_timeout pid=$pid pgid=$pgid"
